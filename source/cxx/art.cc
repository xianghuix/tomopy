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
//   TOMOPY implementation

#include "common.hh"
#include "utils.hh"
#include "utils_cuda.hh"

BEGIN_EXTERN_C
#include "art.h"
#include "utils.h"
END_EXTERN_C

#include <algorithm>
#include <cstdlib>
#include <memory>
#include <numeric>

//======================================================================================//

int
cxx_art(const float* data, int dy, int dt, int dx, const float* center,
        const float* theta, float* recon, int ngridx, int ngridy, int num_iter)
{
    // check to see if the C implementation is requested
    bool use_c_algorithm = GetEnv<bool>("TOMOPY_USE_C_ART", false);
    use_c_algorithm      = GetEnv<bool>("TOMOPY_USE_C_ALGORITHMS", use_c_algorithm);
    // if C implementation is requested, return non-zero (failure)
    if(use_c_algorithm)
        return scast<int>(false);

    auto tid = GetThisThreadID();
    ConsumeParameters(tid);
    static std::atomic<int> active;
    int                     count = active++;

    START_TIMER(cxx_timer);
    TIMEMORY_AUTO_TIMER("");

    printf("[%lu]> %s : nitr = %i, dy = %i, dt = %i, dx = %i, nx = %i, ny = %i\n",
           GetThisThreadID(), __FUNCTION__, num_iter, dy, dt, dx, ngridx, ngridy);

    {
        TIMEMORY_AUTO_TIMER("");
        run_algorithm(art_cpu, art_cuda, data, dy, dt, dx, center, theta, recon, ngridx,
                      ngridy, num_iter);
    }

    auto tcount = GetEnv("TOMOPY_PYTHON_THREADS", HW_CONCURRENCY);
    auto remain = --active;
    REPORT_TIMER(cxx_timer, __FUNCTION__, count, tcount);
    if(remain == 0)
    {
        std::stringstream ss;
        PrintEnv(ss);
        printf("[%lu] Reporting environment...\n\n%s\n", GetThisThreadID(),
               ss.str().c_str());
    }
    else
    {
        printf("[%lu] Threads remaining: %i...\n", GetThisThreadID(), remain);
    }

    return scast<int>(true);
}

//======================================================================================//

void
art_cpu(const float* data, int dy, int dt, int dx, const float* center,
        const float* theta, float* recon, int ngridx, int ngridy, int num_iter)
{
    ConsumeParameters(data, dy, dt, dx, center, theta, recon, ngridx, ngridy, num_iter);

    TIMEMORY_AUTO_TIMER("[cpu]");

    throw std::runtime_error("ART algorithm has not been implemented for CXX");
}

//======================================================================================//
#if !defined(TOMOPY_USE_CUDA)
void
art_cuda(const float* data, int dy, int dt, int dx, const float* center,
         const float* theta, float* recon, int ngridx, int ngridy, int num_iter)
{
    ConsumeParameters(data, dy, dt, dx, center, theta, recon, ngridx, ngridy, num_iter);
    TIMEMORY_AUTO_TIMER("[cuda]");
    throw std::runtime_error("ART algorithm has not been implemented for CUDA");

    /*
    uintmax_t _nx = scast<uintmax_t>(ngridx);
    uintmax_t _ny = scast<uintmax_t>(ngridy);
    uintmax_t _dy = scast<uintmax_t>(dy);
    uintmax_t _dt = scast<uintmax_t>(dt);
    uintmax_t _dx = scast<uintmax_t>(dx);
    uintmax_t _nd = _dy * _dt * _dx;  // number of total entries
    uintmax_t _ng = _nx + _ny;        // number of grid points

    //------------------------------------------------------------------------//

    tomo_data* master_gpu_data = new tomo_data({
        dy, dt, dx, ngridx, ngridy,
        // pointers
        gpu_malloc<int>(1),                         // asize
        gpu_malloc<int>(1),                         // bsize
        gpu_malloc<int>(1),                         // csize
        gpu_malloc<float>(_nx + 1),                 // gridx
        gpu_malloc<float>(_ny + 1),                 // gridy
        gpu_malloc<float>(_ny + 1),                 // coordx
        gpu_malloc<float>(_nx + 1),                 // coordy
        gpu_malloc<float>(_ng),                     // ax
        gpu_malloc<float>(_ng),                     // ay
        gpu_malloc<float>(_ng),                     // bx
        gpu_malloc<float>(_ng),                     // by
        gpu_malloc<float>(_ng),                     // coorx
        gpu_malloc<float>(_ng),                     // coory
        gpu_malloc<float>(_ng),                     // dist
        gpu_malloc<int>(_ng),                       // indi
        gpu_malloc<float>(_nd),                     // simdata
        malloc_and_memcpy(recon, _dy * _nx * _ny),  // model (recon)
        malloc_and_memcpy(center, _dy),             // center
        malloc_and_memcpy(theta, _dt),              // theta
        gpu_malloc<float>(1),                       // sum
        gpu_malloc<float>(1),                       // mov
        malloc_and_memcpy(data, _nd)                // data
    });
    */
}
#endif

//======================================================================================//
