//  Copyright (c) 2015, UChicago Argonne, LLC. All rights reserved.
//  Copyright 2015. UChicago Argonne, LLC. This software was produced
//  under U.S. Government contract DE-AC02-06CH11357 for Argonne National
//  Laboratory (ANL), which is operated by UChicago Argonne, LLC for the
//  U.S. Department of Energy. The U.S. Government has rights to use,
//  reproduce, and distribute this software.  NEITHER THE GOVERNMENT NOR
//  UChicago Argonne, LLC MAKES ANY WARRANTY, EXPRESS OR IMPLIED, OR
//  ASSUMES ANY LIABILITY FOR THE USE OF THIS SOFTWARE.  If software is
//  modified to produce derivative works, such modified software should
//  be clearly marked, so as not to confuse it with the version available
//  from ANL.
//  Additionally, redistribution and use in source and binary forms, with
//  or without modification, are permitted provided that the following
//  conditions are met:
//      * Redistributions of source code must retain the above copyright
//        notice, this list of conditions and the following disclaimer.
//      * Redistributions in binary form must reproduce the above copyright
//        notice, this list of conditions and the following disclaimer in
//        the documentation andwith the
//        distribution.
//      * Neither the name of UChicago Argonne, LLC, Argonne National
//        Laboratory, ANL, the U.S. Government, nor the names of its
//        contributors may be used to endorse or promote products derived
//        from this software without specific prior written permission.
//  THIS SOFTWARE IS PROVIDED BY UChicago Argonne, LLC AND CONTRIBUTORS
//  "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
//  LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
//  FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL UChicago
//  Argonne, LLC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
//  INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
//  BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
//  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
//  CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
//  LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
//  ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//  POSSIBILITY OF SUCH DAMAGE.
//  ---------------------------------------------------------------
//   TOMOPY CUDA implementation

#include "common.hh"
#include "gpu.hh"
#include "utils.hh"
#include "utils_cuda.hh"

BEGIN_EXTERN_C
#include "sirt.h"
#include "utils.h"
END_EXTERN_C

#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <memory>
#include <numeric>

//======================================================================================//

#if defined(TOMOPY_USE_NVTX)
extern nvtxEventAttributes_t nvtx_total;
extern nvtxEventAttributes_t nvtx_iteration;
extern nvtxEventAttributes_t nvtx_slice;
extern nvtxEventAttributes_t nvtx_projection;
extern nvtxEventAttributes_t nvtx_update;
extern nvtxEventAttributes_t nvtx_rotate;
#endif

//======================================================================================//

typedef gpu_data::int_type     int_type;
typedef gpu_data::init_data_t  init_data_t;
typedef gpu_data::data_array_t data_array_t;

//======================================================================================//

__global__ void
cuda_sirt_pixels_kernel(int p, int nx, int dx, float* recon, const float* data,
                        const int_type* recon_use, uint16_t* sum_dist)
{
    int d0      = blockIdx.x * blockDim.x + threadIdx.x;
    int dstride = blockDim.x * gridDim.x;

    for(int d = d0; d < dx; d += dstride)
    {
        float sum = 0.0f;
        for(int i = 0; i < nx; ++i)
            sum += recon[d * nx + i];
        for(int i = 0; i < nx; ++i)
            sum_dist[d * nx + i] += (recon_use[d * nx + i] > 0) ? 1 : 0;
        float upd = (data[p * dx + d] - sum);
        if(upd == upd)  // is finite
            for(int i = 0; i < nx; ++i)
                recon[d * nx + i] += upd;
    }
}

//======================================================================================//

__global__ void
cuda_sirt_update_kernel(float* recon, const float* update, const uint32_t* sum_dist,
                        int dx, int size)
{
    int i0      = blockIdx.x * blockDim.x + threadIdx.x;
    int istride = blockDim.x * gridDim.x;

    float fdx = scast<float>(dx);
    for(int i = i0; i < size; i += istride)
    {
        if(sum_dist[i] != 0.0f)
            atomicAdd(&recon[i], update[i] / scast<float>(sum_dist[i]) / fdx);
    }
}

//======================================================================================//

void
sirt_gpu_compute_projection(data_array_t& _gpu_data, int s, int p, int dy, int dt, int dx,
                            int nx, int ny, const float* theta, uint32_t* global_sum_dist)
{
    auto _cache = _gpu_data[GetThisThreadID() % _gpu_data.size()];

#if defined(DEBUG)
    printf("[%lu] Running slice %i, projection %i on device %i...\n", GetThisThreadID(),
           s, p, _cache->device());
#endif

    // ensure running on proper device
    cuda_set_device(_cache->device());

    // calculate some values
    float        theta_p_rad  = fmodf(theta[p] + halfpi, twopi);
    float        theta_p_deg  = theta_p_rad * degrees;
    const float* data         = _cache->data() + s * dt * dx;
    const float* recon        = _cache->recon() + s * nx * ny;
    float*       update       = _cache->update() + s * nx * ny;
    uint32_t*    sum_dist     = global_sum_dist + s * nx * ny;
    uint16_t*    sum_dist_tmp = _cache->sum_dist();
    auto*        use_rot      = _cache->use_rot();
    auto*        use_tmp      = _cache->use_tmp();
    float*       rot          = _cache->rot();
    float*       tmp          = _cache->tmp();
    int          block        = _cache->block();
    int          grid         = _cache->compute_grid(dx);
    cudaStream_t stream       = _cache->stream();

    gpu_memset<uint16_t>(sum_dist_tmp, 0, nx * ny, stream);
    gpu_memset<int_type>(use_rot, 0, nx * ny, stream);
    gpu_memset<float>(rot, 0, nx * ny, stream);
    gpu_memset<float>(tmp, 0, nx * ny, stream);

    // forward-rotate
    cuda_rotate_ip(use_rot, use_tmp, -theta_p_rad, -theta_p_deg, nx, ny, stream, GPU_NN);
    cuda_rotate_ip(rot, recon, -theta_p_rad, -theta_p_deg, nx, ny, stream);
    // compute simdata
    cuda_sirt_pixels_kernel<<<grid, block, 0, stream>>>(p, nx, dx, rot, data, use_rot,
                                                        sum_dist_tmp);
    // back-rotate
    cuda_rotate_ip(tmp, rot, theta_p_rad, theta_p_deg, nx, ny, stream);
    // update shared update array
    cuda_atomic_sum_kernel<<<grid, block, 0, stream>>>(update, tmp, nx * ny, 1.0f);
    // update shared sum_dist array
    cuda_atomic_sum_kernel<uint32_t, uint16_t>
        <<<grid, block, 0, stream>>>(sum_dist, sum_dist_tmp, nx * ny, 1);
    // synchronize the stream (do this frequently to avoid backlog)
    stream_sync(stream);
}

//--------------------------------------------------------------------------------------//

void
sirt_cuda(const float* cpu_data, int dy, int dt, int dx, const float* center,
          const float* theta, float* cpu_recon, int ngridx, int ngridy, int num_iter)
{
    typedef decltype(HW_CONCURRENCY) nthread_type;

    auto num_devices = cuda_device_count();
    if(num_devices == 0)
        throw std::runtime_error("No CUDA device(s) available");

    printf("[%lu]> %s : nitr = %i, dy = %i, dt = %i, dx = %i, nx = %i, ny = %i\n",
           GetThisThreadID(), __FUNCTION__, num_iter, dy, dt, dx, ngridx, ngridy);

    // initialize nvtx data
    init_nvtx();
    // print device info
    cuda_device_query();
    // thread counter for device assignment
    static std::atomic<int> ntid;

    // compute some properties (expected python threads, max threads, device assignment)
    auto min_threads = nthread_type(1);
    auto pythreads   = GetEnv("TOMOPY_PYTHON_THREADS", HW_CONCURRENCY);
    auto max_threads = HW_CONCURRENCY / std::max(pythreads, min_threads);
    auto nthreads    = std::max(GetEnv("TOMOPY_NUM_THREADS", max_threads), min_threads);
    int  device      = (ntid++) % num_devices;  // assign to device

#if defined(TOMOPY_USE_PTL)
    typedef TaskManager manager_t;
    TaskRunManager*     run_man = gpu_run_manager();
    init_run_manager(run_man, nthreads);
    TaskManager* task_man = run_man->GetTaskManager();
    ThreadPool*  tp       = task_man->thread_pool();
#else
    typedef void manager_t;
    void*        task_man = nullptr;
#endif

    TIMEMORY_AUTO_TIMER("");

    // GPU allocated copies
    cuda_set_device(device);
    printf("[%lu] Running on device %i...\n", GetThisThreadID(), device);

    uintmax_t   recon_pixels = scast<uintmax_t>(dy * ngridx * ngridy);
    auto        block        = GetBlockSize();
    auto        grid         = ComputeGridSize(recon_pixels, block);
    auto        main_stream  = create_streams(1);
    float*      update   = gpu_malloc_and_memset<float>(recon_pixels, 0, *main_stream);
    uint32_t*   sum_dist = gpu_malloc_and_memset<uint32_t>(recon_pixels, 0, *main_stream);
    init_data_t init_data  = gpu_data::initialize(device, nthreads, dy, dt, dx, ngridx,
                                                 ngridy, cpu_recon, cpu_data, update);
    data_array_t _gpu_data = std::get<0>(init_data);
    float*       recon     = std::get<1>(init_data);
    float*       data      = std::get<2>(init_data);
    for(auto& itr : _gpu_data)
        itr->alloc_sum_dist();

    NVTX_RANGE_PUSH(&nvtx_total);

    for(int i = 0; i < num_iter; i++)
    {
        // timing and profiling
        TIMEMORY_AUTO_TIMER("");
        NVTX_RANGE_PUSH(&nvtx_iteration);
        START_TIMER(t_start);

        // sync the main stream
        stream_sync(*main_stream);

        // reset global update and sum_dist
        gpu_memset(update, 0, recon_pixels, *main_stream);
        gpu_memset(sum_dist, 0, recon_pixels, *main_stream);

        // sync and reset
        gpu_data::sync(_gpu_data);
        gpu_data::reset(_gpu_data);

        // execute the loop over slices and projection angles
        execute<manager_t, data_array_t>(task_man, dy, dt, std::ref(_gpu_data),
                                         sirt_gpu_compute_projection, dy, dt, dx, ngridx,
                                         ngridy, theta, sum_dist);

        // sync the thread streams
        gpu_data::sync(_gpu_data);

        // sync the main stream
        stream_sync(*main_stream);

        // update the global recon with global update and sum_dist
        cuda_sirt_update_kernel<<<grid, block, 0, *main_stream>>>(recon, update, sum_dist,
                                                                  dx, recon_pixels);

        // stop profile range and report timing
        NVTX_RANGE_POP(0);
        REPORT_TIMER(t_start, "iteration", i, num_iter);
    }

    // sync the main stream
    stream_sync(*main_stream);

    gpu2cpu_memcpy<float>(cpu_recon, recon, recon_pixels, *main_stream);

    // sync the main stream
    stream_sync(*main_stream);

    // destroy main stream
    destroy_streams(main_stream, 1);

    // cleanup
    cudaFree(recon);
    cudaFree(data);
    cudaFree(update);
    cudaFree(sum_dist);

    NVTX_RANGE_POP(0);
}

//======================================================================================//
