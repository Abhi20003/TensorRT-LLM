/*
 * Copyright (c) 2019-2024, NVIDIA CORPORATION.  All rights reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include "tensorrt_llm/kernels/beamSearchKernels.h"
#include "tensorrt_llm/layers/beamSearchLayer.h"
#include "tensorrt_llm/layers/defaultDecodingParams.h"
#include "tensorrt_llm/layers/layerUtils.h"

#include <limits>

using namespace tensorrt_llm::common;
using namespace tensorrt_llm::kernels;

namespace tensorrt_llm::layers
{

template <typename T>
BeamSearchLayer<T>::BeamSearchLayer(
    DecoderDomain const& decoderDomain, cudaStream_t stream, std::shared_ptr<IAllocator> allocator)
    : BaseLayer(decoderDomain, stream, std::move(allocator))
    , mVocabSize(decoderDomain.getVocabSize())
    , mVocabSizePadded(decoderDomain.getVocabSizePadded())
{
    TLLM_LOG_TRACE(__PRETTY_FUNCTION__);
}

template <typename T>
BeamSearchLayer<T>::~BeamSearchLayer()
{
    TLLM_LOG_TRACE(__PRETTY_FUNCTION__);
}

template <typename T>
void BeamSearchLayer<T>::setup(runtime::SizeType32 const batchSize, runtime::SizeType32 const beamWidth,
    runtime::SizeType32 const* batchSlots, std::shared_ptr<BaseSetupParams> const& baseSetupParams)
{
    TLLM_LOG_TRACE("%s start", __PRETTY_FUNCTION__);
    TLLM_CHECK_WITH_INFO(
        beamWidth <= nMaxBeamWidth, std::string("Beam width is larger than the maximum supported (64)."));

    auto setupParams = std::dynamic_pointer_cast<BeamSearchSetupParams>(baseSetupParams);

    mDiversityRateHost.resize(batchSize);
    mLengthPenaltyHost.resize(batchSize);
    mEarlyStoppingHost.resize(batchSize);
    allocateBuffer(batchSize, beamWidth);

    auto constexpr fltMax = std::numeric_limits<float>::max();
    auto constexpr fltMin = std::numeric_limits<float>::lowest();
    auto constexpr fltEpsilon = std::numeric_limits<float>::epsilon();

    FillBuffers const fillBuffers{batchSize, batchSize, mStream};
    fillBuffers(setupParams->beamSearchDiversityRate, DefaultDecodingParams::getBeamSearchDiversity(),
        mDiversityRateHost, mDiversityRateDevice, (int*) nullptr, std::make_pair(-fltEpsilon, fltMax),
        "diveristy rate");
    fillBuffers(setupParams->lengthPenalty, DefaultDecodingParams::getLengthPenalty(), mLengthPenaltyHost,
        mLengthPenaltyDevice, (int*) nullptr, std::make_pair(fltMin, fltMax), "length penalty");
    fillBuffers(setupParams->earlyStopping, DefaultDecodingParams::getEarlyStopping(), mEarlyStoppingHost,
        mEarlyStoppingDevice, (int*) nullptr, std::make_pair(fltMin, fltMax), "early stopping");
    mHasDiffRuntimeArgs = setupParams->hasDiffRuntimeArgs;

    TLLM_LOG_TRACE("%s stop", __PRETTY_FUNCTION__);
}

__global__ void updateCacheIndirectionKernel(
    int* tgtCI, int const* srcCI, BeamHypotheses bh, int const nMaxAttentionWindow, int const nSinkTokenLength)
{
    // Update indirections from steps `bh.inputLength[indexBatchBeam]` to step `sequenceLengths[indexBatchBeam]`
    int const step = threadIdx.x + blockIdx.x * blockDim.x;
    int const indexBatchBeam = blockIdx.y;
    int const nBS{bh.nBatchSize};
    int const nBM{bh.nBeamWidth};
    int const nMSL{bh.nMaxSeqLen};
    int const indexBatch = indexBatchBeam / nBM;
    int const indexBeam = indexBatchBeam % nBM;
    int const lastStep{bh.sequenceLengths[indexBatchBeam] - 1}; // the sequenceLengths is updated, need to minus 1

    // Return early when the indexBatchBeam or step is out of the bound
    // No update for the indices of context part since KV Cache is shared
    if (indexBatchBeam >= nBM * nBS || step >= nMSL || step < bh.inputLengths[indexBatchBeam]
        || step < (nMSL - nMaxAttentionWindow) || bh.finished[indexBatchBeam].isFinished())
    {
        return;
    }

    // Keep all past tokens by parentIdsPtr
    int const indexBeamSrc = bh.parentIdsPtr[indexBatch][indexBeam * nMSL + lastStep];
    int const stepCirc = (step >= nSinkTokenLength)
        ? nSinkTokenLength + (step - nSinkTokenLength) % (nMaxAttentionWindow - nSinkTokenLength)
        : step;
    // Consider cyclic kv cache for the indir tables
    uint32_t const tgtOffset = indexBatch * nBM * nMaxAttentionWindow + indexBeam * nMaxAttentionWindow + stepCirc;
    uint32_t const srcOffset = indexBatch * nBM * nMaxAttentionWindow + indexBeamSrc * nMaxAttentionWindow + stepCirc;
    tgtCI[tgtOffset] = (step == lastStep) ? indexBeam : srcCI[srcOffset];
}

template <typename T>
void BeamSearchLayer<T>::forwardAsyncSingleRequest(
    std::shared_ptr<BaseDecodingOutputs> const& baseOutputs, std::shared_ptr<BaseDecodingInputs> const& baseInputs)
{
    TLLM_LOG_TRACE("%s start", __PRETTY_FUNCTION__);

    auto ip = std::dynamic_pointer_cast<BeamSearchInputParams>(baseInputs);
    auto op = std::dynamic_pointer_cast<BeamSearchOutputs>(baseOutputs);

    TLLM_CHECK_WITH_INFO(op->beamHypotheses, std::string("Output BeamHypotheses is not set."));
    TLLM_CHECK_WITH_INFO(op->sequenceLength->template getPtr<int>() != nullptr || mLengthPenaltyDevice == nullptr,
        std::string("Current sequence lengths must be set for length penalty computation."));
    TLLM_CHECK_WITH_INFO(ip->ite == 0, "Pipeline Parallelism is not supported yet !");

    BeamHypotheses& bh{*op->beamHypotheses};
    // bh's members already initialized in op: *CBA, batchDones
    // bh's members not used in function: outputIds, logProbs, outputIdsUnfinish, parentIdsUnfinish
    bh.nMaxBatchSize = static_cast<std::int32_t>(op->outputIdsPtr.shape[0]);
    bh.nBatchSize = ip->localBatchSize;
    bh.nBeamWidth = static_cast<std::int32_t>(op->outputIdsPtr.shape[1]);
    bh.nIte = ip->ite;
    bh.nMaxSeqLen = static_cast<std::int32_t>(op->outputIdsPtr.shape[2]);
    bh.nVocabSize = mVocabSizePadded;
    bh.diversityRates = mDiversityRateDevice;
    bh.lengthPenalties = mLengthPenaltyDevice;
    bh.earlyStoppings = mEarlyStoppingDevice;
    bh.inputLengths = ip->inputLengths->template getPtr<int const>();
    bh.endIds = ip->endIds.template getPtr<int const>();
    bh.logProbsTiled = (op->outputLogProbs) ? op->outputLogProbs->template getPtr<float>() : nullptr;
    bh.sequenceLengths = op->sequenceLength->template getPtr<int>();
    bh.cumLogProbs = op->cumLogProbs->template getPtr<float>();
    bh.finished = reinterpret_cast<FinishedState*>(op->finished->template getPtr<FinishedState::UnderlyingType>());
    bh.outputIdsPtr = op->outputIdsPtr.template getPtr<int*>();
    bh.parentIdsPtr = op->parentIdsPtr.template getPtr<int*>();

    T const* logits = ip->logits.template getPtr<T>();
    T const* bias = static_cast<T const*>(nullptr);
    TLLM_CHECK_WITH_INFO(mWorkspaceSize >= 2 * bh.nBatchSize * bh.nBeamWidth * bh.nBeamWidth * 2,
        fmtstr("Workspace size (%lu) is not enough for topk softmax required (%lu).", (uint64_t) mWorkspaceSize,
            (uint64_t) (2 * bh.nMaxBatchSize * bh.nBeamWidth * bh.nBeamWidth * 2)));

    invokeTopkSoftMax(logits, bias, mWorkspace, bh, mStream);
    sync_check_cuda_error();

    if (bh.nBeamWidth > 1)
    {
        auto tgtCI = op->tgtCacheIndirection.template getPtr<int>();
        auto srcCI = ip->srcCacheIndirection.template getPtr<int const>();
        dim3 const grid(roundUp(bh.nMaxSeqLen, 32), bh.nBatchSize * bh.nBeamWidth);
        updateCacheIndirectionKernel<<<grid, 32, 0, mStream>>>(
            tgtCI, srcCI, bh, ip->maxAttentionWindow, ip->sinkTokenLength);
        sync_check_cuda_error();
    }

    TLLM_LOG_TRACE("%s stop", __PRETTY_FUNCTION__);
}

template <typename T>
void BeamSearchLayer<T>::forwardAsync(
    std::shared_ptr<BaseDecodingOutputs> const& baseOutputs, std::shared_ptr<BaseDecodingInputs> const& baseInputs)
{
    TLLM_LOG_TRACE("%s start", __PRETTY_FUNCTION__);
    auto outputs = std::dynamic_pointer_cast<BeamSearchOutputs>(baseOutputs);
    auto params = std::dynamic_pointer_cast<DecodingInputs>(baseInputs);

    auto const localDecoderDomain = getLocalDecoderDomain(params, mDecoderDomain);

    auto batchSlots = params->batchSlots ? params->batchSlots->template getPtr<SizeType32 const>() : nullptr;
    auto const maxSeqLen = outputs->outputIds.shape[outputs->outputIds.shape.size() - 1];
    auto const ite = params->ite;
    auto const step = params->step;

    // common inputs
    auto const& endIds = params->endIds;
    auto const localBatchSize = static_cast<std::size_t>(params->localBatchSize);

    TLLM_CHECK_WITH_INFO(localDecoderDomain.getBeamWidth() > 1,
        "Decoding mode is beam search, but beamWidth <= 1 (%d <= 1)", localDecoderDomain.getBeamWidth());
    TLLM_CHECK_WITH_INFO(params->srcCacheIndirection.has_value(), "srcCacheIndirection is mandatory in beam search.");
    TLLM_CHECK_WITH_INFO(outputs->parentIds.has_value(), "parentIds tensor is mandatory in beam search.");
    TLLM_CHECK_WITH_INFO(outputs->finished.has_value(), "finished tensor is mandatory in beam search.");
    TLLM_CHECK_WITH_INFO(outputs->cumLogProbs.has_value(), "cumLogProbs tensor is mandatory in beam search.");

    // Compute one by one if there are different runtime arguments
    //     due to Batch-Beam-Search is not supported yet, so we need to compute
    size_t const dynamic_decode_batch_size = mHasDiffRuntimeArgs ? 1 : localBatchSize;
    auto const dynamic_decode_total_iteration = mHasDiffRuntimeArgs ? localBatchSize : 1;

    for (uint32_t dynamic_ite = 0; dynamic_ite < dynamic_decode_total_iteration; ++dynamic_ite)
    {
        auto const dynamic_id_offset = dynamic_ite * dynamic_decode_batch_size * localDecoderDomain.getBeamWidth();
        auto const dynamic_decode_vocab_size_units_offset = dynamic_id_offset * mDecoderDomain.getVocabSizePadded();

        auto const logits_offset
            = params->logits->slice({dynamic_decode_batch_size, params->logits->shape[1], params->logits->shape[2]},
                dynamic_decode_vocab_size_units_offset);
        auto const end_id_offset = endIds.slice({dynamic_decode_batch_size}, dynamic_ite * dynamic_decode_batch_size);

        auto forwardParams = std::make_shared<BeamSearchInputParams>(step, ite, logits_offset, end_id_offset,
            *params->srcCacheIndirection, static_cast<std::int32_t>(params->maxAttentionWindow),
            static_cast<std::int32_t>(params->sinkTokenLength), static_cast<std::int32_t>(maxSeqLen),
            dynamic_decode_batch_size);

        if (params->inputLengths)
        {
            forwardParams->inputLengths = params->inputLengths->slice(
                {dynamic_decode_batch_size * localDecoderDomain.getBeamWidth()}, dynamic_id_offset);
        }

        auto outputParams = std::make_shared<BeamSearchOutputs>(outputs->outputIds);

        outputParams->parentIds = std::move(outputs->parentIds);
        outputParams->tgtCacheIndirection = std::move(outputs->tgtCacheIndirection);
        outputParams->outputIdsPtr = std::move(outputs->outputIdsPtr);
        outputParams->parentIdsPtr = std::move(outputs->parentIdsPtr);
        outputParams->sequenceLength = outputs->sequenceLength->slice(
            {dynamic_decode_batch_size * localDecoderDomain.getBeamWidth()}, dynamic_id_offset);
        outputParams->finished = outputs->finished->slice(
            {dynamic_decode_batch_size * localDecoderDomain.getBeamWidth()}, dynamic_id_offset);
        outputParams->cumLogProbs = outputs->cumLogProbs->slice(
            {dynamic_decode_batch_size * localDecoderDomain.getBeamWidth()}, dynamic_id_offset);
        outputParams->outputLogProbs = outputs->outputLogProbsTiled; // notice: use tiled tensor
        outputParams->beamHypotheses = std::move(outputs->beamHypotheses);

        // beamSearchDiversityRate is only supported when using BeamHypotheses
        forwardAsyncSingleRequest(outputParams, forwardParams);
    } // end of dynamic_ite
    TLLM_LOG_TRACE("%s stop", __PRETTY_FUNCTION__);
}

template <typename T>
void BeamSearchLayer<T>::allocateBuffer(runtime::SizeType32 const batchSize, runtime::SizeType32 const beamWidth)
{
    TLLM_LOG_TRACE("%s start", __PRETTY_FUNCTION__);
    int const nPadBeamWidth = padToNextPowerOfTwo(beamWidth);
    // Unit of mWorkspaceSize is number of elements (not Byte), align to 4 for further optimization
    size_t nTopK = batchSize * nPadBeamWidth * nPadBeamWidth * 2;
    size_t nTempBuffer = batchSize * nPadBeamWidth * nMaxVocabPartForStage1FastKernel * (2 * (nPadBeamWidth * 2) + 2);
    mWorkspaceSize = roundUp(nTopK, 4) * 2 + roundUp(nTempBuffer, 4);
    mWorkspace = mAllocator->reMalloc(mWorkspace, sizeof(float) * mWorkspaceSize, true);
    mDiversityRateDevice = mAllocator->reMalloc(mDiversityRateDevice, sizeof(float) * batchSize, false);
    mLengthPenaltyDevice = mAllocator->reMalloc(mLengthPenaltyDevice, sizeof(float) * batchSize, false);
    mEarlyStoppingDevice = mAllocator->reMalloc(mEarlyStoppingDevice, sizeof(int) * batchSize, false);
    mIsAllocateBuffer = true;
    TLLM_LOG_TRACE("%s stop", __PRETTY_FUNCTION__);
}

template <typename T>
void BeamSearchLayer<T>::freeBuffer()
{
    TLLM_LOG_TRACE("%s start", __PRETTY_FUNCTION__);
    if (mIsAllocateBuffer)
    {
        mAllocator->free((void**) (&mWorkspace));
        mAllocator->free((void**) (&mDiversityRateDevice));
        mAllocator->free((void**) (&mLengthPenaltyDevice));
        mAllocator->free((void**) (&mEarlyStoppingDevice));
        mIsAllocateBuffer = false;
    }
    TLLM_LOG_TRACE("%s stop", __PRETTY_FUNCTION__);
}

template class BeamSearchLayer<float>;
template class BeamSearchLayer<half>;

} // namespace tensorrt_llm::layers
