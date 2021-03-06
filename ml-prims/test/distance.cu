/*
 * Copyright (c) 2018, NVIDIA CORPORATION.
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

#include <gtest/gtest.h>
#include "distance/distance.h"
#include "test_utils.h"
#include "random/rng.h"
#include "cuda_utils.h"


namespace MLCommon {
namespace Distance {

template <typename Type>
__global__ void naiveDistanceKernel(Type* dist, const Type* x, const Type* y,
                                    int m, int n, int k, DistanceType type) {
    int midx = threadIdx.x + blockIdx.x * blockDim.x;
    int nidx = threadIdx.y + blockIdx.y * blockDim.y;
    if(midx >= m || nidx >= n)
        return;
    Type acc = Type(0);
    for(int i=0; i<k; ++i) {
        auto diff = x[i + midx * k] - y[i + nidx * k];
        acc += diff * diff;
    }
    if(type == EucExpandedL2Sqrt || type == EucUnexpandedL2Sqrt)
        acc = mySqrt(acc);
    dist[midx * n + nidx] = acc;
}

template <typename Type>
__global__ void naiveL1DistanceKernel(
    Type* dist, const Type* x, const Type* y,
    int m, int n, int k)
{
    int midx = threadIdx.x + blockIdx.x * blockDim.x;
    int nidx = threadIdx.y + blockIdx.y * blockDim.y;
    if(midx >= m || nidx >= n) {
        return;
    }

    Type acc = Type(0);
    for(int i = 0; i < k; ++i) {
        auto a = x[i + midx * k];
        auto b = y[i + nidx * k];
        auto diff = (a > b) ? (a - b) : (b - a);
        acc += diff;
    }

    dist[midx * n + nidx] = acc;
}

template <typename Type>
__global__ void naiveCosineDistanceKernel(
    Type* dist, const Type* x, const Type* y,
    int m, int n, int k)
{
    int midx = threadIdx.x + blockIdx.x * blockDim.x;
    int nidx = threadIdx.y + blockIdx.y * blockDim.y;
    if(midx >= m || nidx >= n) {
        return;
    }

    Type acc_a  = Type(0);
    Type acc_b  = Type(0);
    Type acc_ab = Type(0);

    for(int i = 0; i < k; ++i) {
        auto a = x[i + midx * k];
        auto b = y[i + nidx * k];

        acc_a  += a * a;
        acc_b  += b * b;
        acc_ab += a * b;
    }

    dist[midx * n + nidx] = acc_ab / (sqrt(acc_a) * sqrt(acc_b));
}

template <typename Type>
void naiveDistance(Type* dist, const Type* x, const Type* y, int m, int n, int k,
                   DistanceType type) {
    static const dim3 TPB(16, 32, 1);
    dim3 nblks(ceildiv(m, (int)TPB.x), ceildiv(n, (int)TPB.y), 1);

    switch (type) {
        case EucUnexpandedL1:
            naiveL1DistanceKernel<Type><<<nblks,TPB>>>(dist, x, y, m, n, k);
            break;
        case EucUnexpandedL2Sqrt:
        case EucUnexpandedL2:
        case EucExpandedL2Sqrt:
        case EucExpandedL2:
            naiveDistanceKernel<Type><<<nblks,TPB>>>(dist, x, y, m, n, k, type);
            break;
        case EucExpandedCosine:
            naiveCosineDistanceKernel<Type><<<nblks,TPB>>>(dist, x, y, m, n, k);
            break;
        default:
            FAIL() << "should be here\n";
    }
    CUDA_CHECK(cudaPeekAtLastError());
}

template <typename T>
struct DistanceInputs {
    T tolerance;
    int m, n, k;
    DistanceType type;
    unsigned long long int seed;
};

template <typename T>
::std::ostream& operator<<(::std::ostream& os, const DistanceInputs<T>& dims) {
    return os;
}

template <typename T>
struct OutParams {
    T* dist;
    T* dist2;
};

template <typename T>
struct InParams {
  T threshold;
};

template <typename T>
class DistanceTest: public ::testing::TestWithParam<DistanceInputs<T> > {
public:
    void SetUp() override {
        params = ::testing::TestWithParam<DistanceInputs<T>>::GetParam();
        Random::Rng<T> r(params.seed);
        int m = params.m;
        int n = params.n;
        int k = params.k;
        allocate(x, m*k);
        allocate(y, n*k);
        allocate(dist_ref, m*n);
        allocate(dist, m*n);
        allocate(dist2, m*n);
        r.uniform(x, m*k, T(-1.0), T(1.0));
        r.uniform(y, n*k, T(-1.0), T(1.0));
        InParams<T> in_params = {-1.f};
        OutParams<T> out_params = {dist, dist2};
        naiveDistance(dist_ref, x, y, m, n, k, params.type);
        char* workspace = nullptr;
        size_t worksize = 0;

        typedef cutlass::Shape<8, 128, 128> OutputTile_t;

        distance<T,T,InParams<T>,OutParams<T>,OutputTile_t>(x, y, m, n, k,
                                                            in_params, out_params, params.type,
                                                            nullptr, worksize);
        if (worksize != 0) {
            allocate(workspace, worksize);
        }

        auto fin_op = [] __device__ (T d_val, int g_d_idx,
                            const InParams<T>& in_params, OutParams<T>& out_params) {
                        out_params.dist2[g_d_idx] = (d_val < in_params.threshold)? 0.f : d_val;
                        return d_val;
                      };
        distance<T,T,InParams<T>,OutParams<T>,OutputTile_t>(x, y, m, n, k,
                                                            in_params, out_params, params.type,
                                                            workspace, worksize,
                                                            fin_op);
        CUDA_CHECK(cudaFree(workspace));
    }

    void TearDown() override {
        CUDA_CHECK(cudaFree(x));
        CUDA_CHECK(cudaFree(y));
        CUDA_CHECK(cudaFree(dist_ref));
        CUDA_CHECK(cudaFree(dist));
        CUDA_CHECK(cudaFree(dist2));
    }

protected:
    DistanceInputs<T> params;
    T *x, *y, *dist_ref, *dist, *dist2;
};

const std::vector<DistanceInputs<float> > inputsf = {
    {0.001f, 1024, 1024,   32, EucExpandedL2,       1234ULL}, // accumulate issue due to x^2 + y^2 -2xy
    {0.001f, 1024,   32, 1024, EucExpandedL2,       1234ULL},
    {0.001f,   32, 1024, 1024, EucExpandedL2,       1234ULL},
    {0.001f, 1024, 1024, 1024, EucExpandedL2,       1234ULL},

    {0.001f, 1024, 1024,   32, EucExpandedL2Sqrt,   1234ULL},
    {0.001f, 1024,   32, 1024, EucExpandedL2Sqrt,   1234ULL},
    {0.001f,   32, 1024, 1024, EucExpandedL2Sqrt,   1234ULL},
    {0.001f, 1024, 1024, 1024, EucExpandedL2Sqrt,   1234ULL},

    {0.001f, 1024, 1024,   32, EucUnexpandedL2,     1234ULL},
    {0.001f, 1024,   32, 1024, EucUnexpandedL2,     1234ULL},
    {0.001f,   32, 1024, 1024, EucUnexpandedL2,     1234ULL},
    {0.001f, 1024, 1024, 1024, EucUnexpandedL2,     1234ULL},

    {0.001f, 1024, 1024,   32, EucUnexpandedL2Sqrt, 1234ULL},
    {0.001f, 1024,   32, 1024, EucUnexpandedL2Sqrt, 1234ULL},
    {0.001f,   32, 1024, 1024, EucUnexpandedL2Sqrt, 1234ULL},
    {0.001f, 1024, 1024, 1024, EucUnexpandedL2Sqrt, 1234ULL},

    // {0.001f, 1024, 1024,   32, EucExpandedCosine,   1234ULL},
    // {0.001f, 1024,   32, 1024, EucExpandedCosine,   1234ULL},
    // {0.001f,   32, 1024, 1024, EucExpandedCosine,   1234ULL},
    // {0.001f, 1024, 1024, 1024, EucExpandedCosine,   1234ULL},

    {0.001f, 1024, 1024,   32, EucUnexpandedL1,     1234ULL},
    {0.001f, 1024,   32, 1024, EucUnexpandedL1,     1234ULL},
    {0.001f,   32, 1024, 1024, EucUnexpandedL1,     1234ULL},
    {0.001f, 1024, 1024, 1024, EucUnexpandedL1,     1234ULL},
};

const std::vector<DistanceInputs<double> > inputsd = {
    {0.001f, 1024, 1024,   32, EucExpandedL2,       1234ULL}, // accumulate issue due to x^2 + y^2 -2xy
    {0.001f, 1024,   32, 1024, EucExpandedL2,       1234ULL},
    {0.001f,   32, 1024, 1024, EucExpandedL2,       1234ULL},
    {0.001f, 1024, 1024, 1024, EucExpandedL2,       1234ULL},

    {0.001f, 1024, 1024,   32, EucExpandedL2Sqrt,   1234ULL},
    {0.001f, 1024,   32, 1024, EucExpandedL2Sqrt,   1234ULL},
    {0.001f,   32, 1024, 1024, EucExpandedL2Sqrt,   1234ULL},
    {0.001f, 1024, 1024, 1024, EucExpandedL2Sqrt,   1234ULL},

    {0.001f, 1024, 1024,   32, EucUnexpandedL2,     1234ULL},
    {0.001f, 1024,   32, 1024, EucUnexpandedL2,     1234ULL},
    {0.001f,   32, 1024, 1024, EucUnexpandedL2,     1234ULL},
    {0.001f, 1024, 1024, 1024, EucUnexpandedL2,     1234ULL},

    {0.001f, 1024, 1024,   32, EucUnexpandedL2Sqrt, 1234ULL},
    {0.001f, 1024,   32, 1024, EucUnexpandedL2Sqrt, 1234ULL},
    {0.001f,   32, 1024, 1024, EucUnexpandedL2Sqrt, 1234ULL},
    {0.001f, 1024, 1024, 1024, EucUnexpandedL2Sqrt, 1234ULL},

    // {0.001f, 1024, 1024,   32, EucExpandedCosine,   1234ULL},
    // {0.001f, 1024,   32, 1024, EucExpandedCosine,   1234ULL},
    // {0.001f,   32, 1024, 1024, EucExpandedCosine,   1234ULL},
    // {0.001f, 1024, 1024, 1024, EucExpandedCosine,   1234ULL},

    {0.001f, 1024, 1024,   32, EucUnexpandedL1,     1234ULL},
    {0.001f, 1024,   32, 1024, EucUnexpandedL1,     1234ULL},
    {0.001f,   32, 1024, 1024, EucUnexpandedL1,     1234ULL},
    {0.001f, 1024, 1024, 1024, EucUnexpandedL1,     1234ULL},
};

// TODO: once all the distance functions are implemented, enable these tests
typedef DistanceTest<float> DistanceTestF;
TEST_P(DistanceTestF, Result) {
  if(params.type == EucExpandedL2 || params.type == EucExpandedL2Sqrt)
    ASSERT_TRUE(devArrMatch(dist_ref, dist2, params.m, params.n,
                            CompareApprox<float>(params.tolerance)));
  else
    ASSERT_TRUE(devArrMatch(dist_ref, dist, params.m, params.n,
                            CompareApprox<float>(params.tolerance)));
}

// TODO: once all the distance functions are implemented, enable these tests
typedef DistanceTest<double> DistanceTestD;
TEST_P(DistanceTestD, Result){
  if(params.type == EucExpandedL2 || params.type == EucExpandedL2Sqrt)
    ASSERT_TRUE(devArrMatch(dist_ref, dist2, params.m, params.n,
                            CompareApprox<double>(params.tolerance)));
  else
    ASSERT_TRUE(devArrMatch(dist_ref, dist, params.m, params.n,
                            CompareApprox<double>(params.tolerance)));
}

INSTANTIATE_TEST_CASE_P(DistanceTests, DistanceTestF, ::testing::ValuesIn(inputsf));

INSTANTIATE_TEST_CASE_P(DistanceTests, DistanceTestD, ::testing::ValuesIn(inputsd));

} // end namespace Distance
} // end namespace MLCommon

