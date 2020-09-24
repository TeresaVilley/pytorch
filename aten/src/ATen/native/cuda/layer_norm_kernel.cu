#include <ATen/native/layer_norm.h>

#include <thrust/tuple.h>

#include <ATen/ATen.h>
#include <ATen/AccumulateType.h>
#include <ATen/Dispatch.h>
#include <ATen/NativeFunctions.h>
#include <ATen/cuda/CUDAApplyUtils.cuh>
#include <ATen/cuda/detail/IndexUtils.cuh>
#include <ATen/native/cuda/block_reduce.cuh>
#include <THC/THCDeviceUtils.cuh>

#include <c10/cuda/CUDAMathCompat.h>

namespace at {
namespace native {

namespace {

constexpr int kCUDANumThreads = 256;
constexpr int kColwiseReduceTileSize = 32;

template <typename T>
__global__ void RowwiseMomentsCUDAKernel(
    int64_t N,
    T eps,
    const T* X,
    T* mean,
    T* rstd) {
  using T_ACC = acc_type<T, true>;
  __shared__ int64_t m0_shared[C10_WARP_SIZE];
  __shared__ T_ACC m1_shared[C10_WARP_SIZE];
  __shared__ T_ACC m2_shared[C10_WARP_SIZE];
  const int64_t i = blockIdx.x;
  int64_t m0 = 0;
  T_ACC m1 = 0;
  T_ACC m2 = 0;
  for (int64_t j = threadIdx.x; j < N; j += blockDim.x) {
    const int64_t index = i * N + j;
    const T_ACC delta = static_cast<T_ACC>(X[index]) - m1;
    ++m0;
    m1 += delta / static_cast<T_ACC>(m0);
    m2 += delta * (static_cast<T_ACC>(X[index]) - m1);
  }
  thrust::tie(m0, m1, m2) = cuda_utils::BlockReduceMoments<T_ACC>(
      m0, m1, m2, m0_shared, m1_shared, m2_shared);
  if (threadIdx.x == 0) {
    m2 = c10::cuda::compat::max(m2 / static_cast<T_ACC>(N), T_ACC(0));
    mean[i] = m1;
    rstd[i] = c10::cuda::compat::rsqrt(m2 + static_cast<T_ACC>(eps));
  }
}

template <typename T>
__global__ void LayerNormForwardCUDAKernel(
    int64_t N,
    const T* X,
    const T* mean,
    const T* rstd,
    const T* gamma,
    const T* beta,
    T* Y) {
  using T_ACC = acc_type<T, true>;
  const int64_t i = blockIdx.x;
  for (int64_t j = threadIdx.x; j < N; j += blockDim.x) {
    const int64_t index = i * N + j;
    const T_ACC gamma_v =
        gamma == nullptr ? T_ACC(1) : static_cast<T_ACC>(gamma[j]);
    const T_ACC beta_v =
        beta == nullptr ? T_ACC(0) : static_cast<T_ACC>(beta[j]);
    Y[index] = (static_cast<T_ACC>(X[index]) - static_cast<T_ACC>(mean[i])) *
            static_cast<T_ACC>(rstd[i]) * gamma_v +
        beta_v;
  }
}

template <typename T>
__global__ void ComputeInternalGradientsCUDAKernel(
    int64_t N,
    const T* dY,
    const T* X,
    const T* gamma,
    acc_type<T, true>* ds,
    acc_type<T, true>* db) {
  using T_ACC = acc_type<T, true>;
  __shared__ T_ACC ds_shared[C10_WARP_SIZE];
  __shared__ T_ACC db_shared[C10_WARP_SIZE];
  const int64_t i = blockIdx.x;
  T_ACC sum1 = 0;
  T_ACC sum2 = 0;
  for (int64_t j = threadIdx.x; j < N; j += blockDim.x) {
    const int64_t index = i * N + j;
    const T_ACC gamma_v =
        gamma == nullptr ? T_ACC(1) : static_cast<T_ACC>(gamma[j]);
    sum1 +=
        static_cast<T_ACC>(dY[index]) * static_cast<T_ACC>(X[index]) * gamma_v;
    sum2 += static_cast<T_ACC>(dY[index]) * gamma_v;
  }
  sum1 = cuda_utils::BlockReduceSum<T_ACC>(sum1, ds_shared);
  sum2 = cuda_utils::BlockReduceSum<T_ACC>(sum2, db_shared);
  if (threadIdx.x == 0) {
    ds[i] = sum1;
    db[i] = sum2;
  }
}

template <typename T>
__global__ void ComputeGradientFusedParamsCUDAKernel(
    int64_t M,
    int64_t N,
    const T* mean,
    const T* rstd,
    const acc_type<T, true>* ds,
    const acc_type<T, true>* db,
    acc_type<T, true>* c1,
    acc_type<T, true>* c2) {
  using T_ACC = acc_type<T, true>;
  const int64_t index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < M) {
    const T_ACC s = T_ACC(1) / static_cast<T_ACC>(N);
    const T_ACC a = (db[index] * static_cast<T_ACC>(mean[index]) - ds[index]) *
        static_cast<T_ACC>(rstd[index]) * static_cast<T_ACC>(rstd[index]) *
        static_cast<T_ACC>(rstd[index]) * s;
    c1[index] = a;
    c2[index] =
        -(a * static_cast<T_ACC>(mean[index]) +
          db[index] * static_cast<T_ACC>(rstd[index]) * s);
  }
}

template <typename T>
__global__ void LayerNormBackwardCUDAKenrel(
    int64_t N,
    const T* dY,
    const T* X,
    const T* gamma,
    const T* a,
    const acc_type<T, true>* b,
    const acc_type<T, true>* c,
    T* dX) {
  using T_ACC = acc_type<T, true>;
  const int64_t i = blockIdx.x;
  for (int64_t j = threadIdx.x; j < N; j += blockDim.x) {
    const int64_t index = i * N + j;
    const T_ACC gamma_v =
        gamma == nullptr ? T_ACC(1) : static_cast<T_ACC>(gamma[j]);
    dX[index] =
        static_cast<T_ACC>(a[i]) * static_cast<T_ACC>(dY[index]) * gamma_v +
        b[i] * static_cast<T_ACC>(X[index]) + c[i];
  }
}

template <typename T>
__global__ void GammaBetaBackwardSimpleCUDAKernel(
    int64_t M,
    int64_t N,
    const T* dY,
    const T* X,
    const T* mean,
    const T* rstd,
    T* dg,
    T* db) {
  using T_ACC = acc_type<T, true>;
  const int64_t j = blockIdx.x * blockDim.x + threadIdx.x;
  if (j < N) {
    T_ACC sum1 = 0;
    T_ACC sum2 = 0;
    for (int64_t i = 0; i < M; ++i) {
      const int64_t index = i * N + j;
      sum1 += dg == nullptr ? T_ACC(0)
                            : static_cast<T_ACC>(dY[index]) *
              (static_cast<T_ACC>(X[index]) - static_cast<T_ACC>(mean[i])) *
              static_cast<T_ACC>(rstd[i]);
      sum2 += db == nullptr ? T_ACC(0) : static_cast<T_ACC>(dY[index]);
    }
    if (dg != nullptr) {
      dg[j] = sum1;
    }
    if (db != nullptr) {
      db[j] = sum2;
    }
  }
}

template <typename T>
__global__ void GammaBetaBackwardCUDAKernel(
    int64_t M,
    int64_t N,
    const T* dY,
    const T* X,
    const T* mean,
    const T* rstd,
    T* dg,
    T* db) {
  using T_ACC = acc_type<T, true>;
  __shared__ T_ACC g_shared[kColwiseReduceTileSize][kColwiseReduceTileSize + 1];
  __shared__ T_ACC b_shared[kColwiseReduceTileSize][kColwiseReduceTileSize + 1];
  const int64_t j = blockIdx.x * blockDim.x + threadIdx.x;
  T_ACC dg_sum1 = 0;
  T_ACC dg_sum2 = 0;
  T_ACC db_sum1 = 0;
  T_ACC db_sum2 = 0;
  if (j < N) {
    for (int64_t i = threadIdx.y; i < M; i += blockDim.y * 2) {
      const int64_t i1 = i;
      const int64_t i2 = i + blockDim.y;
      const int64_t index1 = i1 * N + j;
      const int64_t index2 = i2 * N + j;
      dg_sum1 += dg == nullptr ? T_ACC(0)
                               : static_cast<T_ACC>(dY[index1]) *
              (static_cast<T_ACC>(X[index1]) - static_cast<T_ACC>(mean[i1])) *
              static_cast<T_ACC>(rstd[i1]);
      db_sum1 += db == nullptr ? T_ACC(0) : static_cast<T_ACC>(dY[index1]);
      if (i2 < M) {
        dg_sum2 += dg == nullptr ? T_ACC(0)
                                 : static_cast<T_ACC>(dY[index2]) *
                (static_cast<T_ACC>(X[index2]) - static_cast<T_ACC>(mean[i2])) *
                static_cast<T_ACC>(rstd[i2]);
        db_sum2 += db == nullptr ? T_ACC(0) : static_cast<T_ACC>(dY[index2]);
      }
    }
  }
  g_shared[threadIdx.y][threadIdx.x] = dg_sum1;
  g_shared[threadIdx.y + blockDim.y][threadIdx.x] = dg_sum2;
  b_shared[threadIdx.y][threadIdx.x] = db_sum1;
  b_shared[threadIdx.y + blockDim.y][threadIdx.x] = db_sum2;
  __syncthreads();
  T_ACC sum1 = g_shared[threadIdx.x][threadIdx.y];
  T_ACC sum2 = b_shared[threadIdx.x][threadIdx.y];
  sum1 = cuda_utils::WarpReduceSum(sum1);
  sum2 = cuda_utils::WarpReduceSum(sum2);
  if (threadIdx.x == 0) {
    const int64_t j = blockIdx.x * blockDim.x + threadIdx.y;
    if (j < N) {
      if (dg != nullptr) {
        dg[j] = sum1;
      }
      if (db != nullptr) {
        db[j] = sum2;
      }
    }
  }
  sum1 = g_shared[threadIdx.x][threadIdx.y + blockDim.y];
  sum2 = b_shared[threadIdx.x][threadIdx.y + blockDim.y];
  sum1 = cuda_utils::WarpReduceSum(sum1);
  sum2 = cuda_utils::WarpReduceSum(sum2);
  if (threadIdx.x == 0) {
    const int64_t j = blockIdx.x * blockDim.x + threadIdx.y + blockDim.y;
    if (j < N) {
      if (dg != nullptr) {
        dg[j] = sum1;
      }
      if (db != nullptr) {
        db[j] = sum2;
      }
    }
  }
}

template <typename T>
void LayerNormKernelImplInternal(
    const Tensor& X,
    const Tensor& gamma,
    const Tensor& beta,
    int64_t M,
    int64_t N,
    T eps,
    Tensor* Y,
    Tensor* mean,
    Tensor* rstd) {
  TORCH_CHECK(X.numel() == M * N);
  TORCH_CHECK(!gamma.defined() || gamma.numel() == N);
  TORCH_CHECK(!beta.defined() || beta.numel() == N);
  if (M == 0) {
    return;
  }
  const T* X_data = X.data_ptr<T>();
  const T* gamma_data = gamma.defined() ? gamma.data_ptr<T>() : nullptr;
  const T* beta_data = beta.defined() ? beta.data_ptr<T>() : nullptr;
  T* Y_data = Y->data_ptr<T>();
  T* mean_data = mean->data_ptr<T>();
  T* rstd_data = rstd->data_ptr<T>();
  cudaStream_t cuda_stream = at::cuda::getCurrentCUDAStream();
  RowwiseMomentsCUDAKernel<T>
      <<<M, cuda_utils::kCUDABlockReduceNumThreads, 0, cuda_stream>>>(
          N, eps, X_data, mean_data, rstd_data);
  LayerNormForwardCUDAKernel<T><<<M, kCUDANumThreads, 0, cuda_stream>>>(
      N, X_data, mean_data, rstd_data, gamma_data, beta_data, Y_data);
  AT_CUDA_CHECK(cudaGetLastError());
}

void LayerNormKernelImpl(
    const Tensor& X,
    const Tensor& gamma,
    const Tensor& beta,
    int64_t M,
    int64_t N,
    double eps,
    Tensor* Y,
    Tensor* mean,
    Tensor* rstd) {
  AT_DISPATCH_FLOATING_TYPES_AND2(
      at::ScalarType::Half,
      at::ScalarType::BFloat16,
      X.scalar_type(),
      "LayerNormKernelImpl",
      [&]() {
        LayerNormKernelImplInternal<scalar_t>(
            X, gamma, beta, M, N, static_cast<scalar_t>(eps), Y, mean, rstd);
      });
}

template <typename T>
void LayerNormBackwardKernelImplInternal(
    const Tensor& dY,
    const Tensor& X,
    const Tensor& mean,
    const Tensor& rstd,
    const Tensor& gamma,
    int64_t M,
    int64_t N,
    Tensor* dX,
    Tensor* dgamma,
    Tensor* dbeta) {
  using T_ACC = acc_type<T, true>;
  TORCH_CHECK(dY.numel() == M * N);
  TORCH_CHECK(X.numel() == M * N);
  TORCH_CHECK(mean.numel() == M);
  TORCH_CHECK(rstd.numel() == M);
  TORCH_CHECK(!gamma.defined() || gamma.numel() == N);

  if (M == 0) {
    return;
  }

  const T* dY_data = dY.data_ptr<T>();
  const T* X_data = X.data_ptr<T>();
  const T* mean_data = mean.data_ptr<T>();
  const T* rstd_data = rstd.data_ptr<T>();
  const T* gamma_data = gamma.defined() ? gamma.data_ptr<T>() : nullptr;
  T* dX_data = dX->defined() ? dX->data_ptr<T>() : nullptr;
  cudaStream_t cuda_stream = at::cuda::getCurrentCUDAStream();

  if (dX_data != nullptr) {
    const auto kAccType =
        (X.scalar_type() == kHalf || X.scalar_type() == kBFloat16)
        ? kFloat
        : X.scalar_type();
    Tensor ds = at::empty({M}, X.options().dtype(kAccType));
    Tensor db = at::empty({M}, X.options().dtype(kAccType));
    Tensor scale = at::empty({M}, X.options().dtype(kAccType));
    Tensor bias = at::empty({M}, X.options().dtype(kAccType));
    T_ACC* ds_data = ds.data_ptr<T_ACC>();
    T_ACC* db_data = db.data_ptr<T_ACC>();
    T_ACC* scale_data = scale.data_ptr<T_ACC>();
    T_ACC* bias_data = bias.data_ptr<T_ACC>();
    ComputeInternalGradientsCUDAKernel<T>
        <<<M, cuda_utils::kCUDABlockReduceNumThreads, 0, cuda_stream>>>(
            N, dY_data, X_data, gamma_data, ds_data, db_data);
    const int64_t B = (M + kCUDANumThreads - 1) / kCUDANumThreads;
    ComputeGradientFusedParamsCUDAKernel<T>
        <<<B, kCUDANumThreads, 0, cuda_stream>>>(
            M,
            N,
            mean_data,
            rstd_data,
            ds_data,
            db_data,
            scale_data,
            bias_data);
    LayerNormBackwardCUDAKenrel<T><<<M, kCUDANumThreads, 0, cuda_stream>>>(
        N,
        dY_data,
        X_data,
        gamma_data,
        rstd_data,
        scale_data,
        bias_data,
        dX_data);
  }
  if (dgamma->defined() || dbeta->defined()) {
    T* dgamma_data = dgamma->defined() ? dgamma->data_ptr<T>() : nullptr;
    T* dbeta_data = dbeta->defined() ? dbeta->data_ptr<T>() : nullptr;
    if (M < 512) {
      // For small batch size, do colwise reduce directly.
      const int64_t B = (N + kCUDANumThreads - 1) / kCUDANumThreads;
      GammaBetaBackwardSimpleCUDAKernel<T>
          <<<B, kCUDANumThreads, 0, cuda_stream>>>(
              M,
              N,
              dY_data,
              X_data,
              mean_data,
              rstd_data,
              dgamma_data,
              dbeta_data);
    } else {
      const int64_t B =
          (N + kColwiseReduceTileSize - 1) / kColwiseReduceTileSize;
      constexpr int kThreadX = kColwiseReduceTileSize;
      constexpr int kThreadY = kColwiseReduceTileSize / 2;
      GammaBetaBackwardCUDAKernel<T>
          <<<B, dim3(kThreadX, kThreadY), 0, cuda_stream>>>(
              M,
              N,
              dY_data,
              X_data,
              mean_data,
              rstd_data,
              dgamma_data,
              dbeta_data);
    }
  }
  AT_CUDA_CHECK(cudaGetLastError());
}

void LayerNormBackwardKernelImpl(
    const Tensor& dY,
    const Tensor& X,
    const Tensor& mean,
    const Tensor& rstd,
    const Tensor& gamma,
    int64_t M,
    int64_t N,
    Tensor* dX,
    Tensor* dgamma,
    Tensor* dbeta) {
  AT_DISPATCH_FLOATING_TYPES_AND2(
      at::ScalarType::Half,
      at::ScalarType::BFloat16,
      X.scalar_type(),
      "LayerNormBackwardKernelImpl",
      [&]() {
        LayerNormBackwardKernelImplInternal<scalar_t>(
            dY, X, mean, rstd, gamma, M, N, dX, dgamma, dbeta);
      });
}

} // namespace

REGISTER_DISPATCH(LayerNormKernel, &LayerNormKernelImpl);
REGISTER_DISPATCH(LayerNormBackwardKernel, &LayerNormBackwardKernelImpl);

} // namespace native
} // namespace at
