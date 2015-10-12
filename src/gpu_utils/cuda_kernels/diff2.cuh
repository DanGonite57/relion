#ifndef CUDA_DIFF2_KERNELS_CUH_
#define CUDA_DIFF2_KERNELS_CUH_

#include <cuda_runtime.h>
#include <vector>
#include <iostream>
#include <fstream>
#include "src/gpu_utils/cuda_projector.cuh"
#include "src/gpu_utils/cuda_settings.h"


/*
 *   	DIFFERNECE-BASED KERNELS
 */

template<bool do_3DProjection, int eulers_per_block>
__global__ void cuda_kernel_diff2_coarse(
		XFLOAT *g_eulers,
		XFLOAT *trans_x,
		XFLOAT *trans_y,
		XFLOAT *g_real,
		XFLOAT *g_imag,
		CudaProjectorKernel projector,
		XFLOAT *g_corr,
		XFLOAT *g_diff2s,
		unsigned translation_num,
		int image_size
		)
{
	int bid = blockIdx.x * eulers_per_block;
	int tid = threadIdx.x;

	XFLOAT diff2s[eulers_per_block] = {0.f};
	XFLOAT tx, ty;

	__shared__ XFLOAT s_ref_real[D2C_BLOCK_SIZE*eulers_per_block];
	__shared__ XFLOAT s_ref_imag[D2C_BLOCK_SIZE*eulers_per_block];
	__shared__ XFLOAT s_real[D2C_BLOCK_SIZE];
	__shared__ XFLOAT s_imag[D2C_BLOCK_SIZE];
	__shared__ XFLOAT s_corr[D2C_BLOCK_SIZE];
	__shared__ XFLOAT s_eulers[eulers_per_block*6];

	if (tid < eulers_per_block)
	{
		s_eulers[tid*6  ] = g_eulers[(bid+tid)*9  ];
		s_eulers[tid*6+1] = g_eulers[(bid+tid)*9+1];
		s_eulers[tid*6+2] = g_eulers[(bid+tid)*9+3];
		s_eulers[tid*6+3] = g_eulers[(bid+tid)*9+4];
		s_eulers[tid*6+4] = g_eulers[(bid+tid)*9+6];
		s_eulers[tid*6+5] = g_eulers[(bid+tid)*9+7];
	}

	tx = trans_x[tid%translation_num];
	ty = trans_y[tid%translation_num];

	int max_block_wise_pixel( ceilf( (float)image_size / (float)D2C_BLOCK_SIZE ) * D2C_BLOCK_SIZE );

	for (int init_pixel = 0; init_pixel < max_block_wise_pixel; init_pixel += D2C_BLOCK_SIZE)
	{
		__syncthreads();

		if(init_pixel + tid < image_size)
		{
			int x = (init_pixel + tid) % projector.imgX;
			int y = (int)floorf( (float)(init_pixel + tid) / (float)projector.imgX);

			if (y > projector.maxR)
				y -= projector.imgY;

			#pragma unroll
			for (int i = 0; i < eulers_per_block; i ++)
			{
				if(do_3DProjection)
					projector.project3Dmodel(
						x,y,
						s_eulers[i*6  ],
						s_eulers[i*6+1],
						s_eulers[i*6+2],
						s_eulers[i*6+3],
						s_eulers[i*6+4],
						s_eulers[i*6+5],
						s_ref_real[eulers_per_block * tid + i],
						s_ref_imag[eulers_per_block * tid + i]);
				else
					projector.project2Dmodel(
						x,y,
						s_eulers[i*6  ],
						s_eulers[i*6+1],
						s_eulers[i*6+2],
						s_eulers[i*6+3],
						s_eulers[i*6+4],
						s_eulers[i*6+5],
						s_ref_real[eulers_per_block * tid + i],
						s_ref_imag[eulers_per_block * tid + i]);
			}

			s_real[tid] = g_real[(init_pixel + tid)];
			s_imag[tid] = g_imag[(init_pixel + tid)];
			s_corr[tid] = g_corr[(init_pixel + tid)];
		}

		if ((float) tid / translation_num >= D2C_BLOCK_SIZE/translation_num) //TODO Rest threads can be utilized
			continue;

		__syncthreads();

		for (int i = tid / translation_num; i < D2C_BLOCK_SIZE; i += D2C_BLOCK_SIZE/translation_num)
		{
			if((init_pixel + i) >= image_size) break;

			int x = (init_pixel + i) % projector.imgX;
			int y = (int)floorf( (float)(init_pixel + i) / (float)projector.imgX);

			if (y > projector.maxR)
				y -= projector.imgY;

			XFLOAT s, c;
			sincosf( x * tx + y * ty , &s, &c);
			XFLOAT real = c * s_real[i] - s * s_imag[i];
			XFLOAT imag = c * s_imag[i] + s * s_real[i];

			#pragma unroll
			for (int j = 0; j < eulers_per_block; j ++)
			{
				XFLOAT diff_real =  s_ref_real[eulers_per_block * i + j] - real;
				XFLOAT diff_imag =  s_ref_imag[eulers_per_block * i + j] - imag;
				diff2s[j] += (diff_real * diff_real + diff_imag * diff_imag) * s_corr[i] / 2;
			}
		}
	}

	//Assuming translation_num > block-size
	if ((float) tid / translation_num < D2C_BLOCK_SIZE/translation_num)
	{
		#pragma unroll
		for (int i = 0; i < eulers_per_block; i ++)
			atomicAdd(&g_diff2s[(bid+i) * translation_num + tid%translation_num], diff2s[i]);
	}
}


template<bool do_3DProjection>
__global__ void cuda_kernel_diff2_fine(
		XFLOAT *g_eulers,
		XFLOAT *g_imgs_real,
		XFLOAT *g_imgs_imag,
		CudaProjectorKernel projector,
		XFLOAT *g_corr_img,
		XFLOAT *g_diff2s,
		unsigned image_size,
		XFLOAT sum_init,
		unsigned long orientation_num,
		unsigned long translation_num,
		unsigned long todo_blocks,
		unsigned long *d_rot_idx,
		unsigned long *d_trans_idx,
		unsigned long *d_job_idx,
		unsigned long *d_job_num
		)
{
	int bid = blockIdx.y * gridDim.x + blockIdx.x;
	int tid = threadIdx.x;

//    // Specialize BlockReduce for a 1D block of 128 threads on type XFLOAT
//    typedef cub::BlockReduce<XFLOAT, 128> BlockReduce;
//    // Allocate shared memory for BlockReduce
//    __shared__ typename BlockReduce::TempStorage temp_storage;

	int pixel;
	XFLOAT ref_real;
	XFLOAT ref_imag;

	__shared__ XFLOAT s[BLOCK_SIZE*PROJDIFF_CHUNK_SIZE]; //We MAY have to do up to PROJDIFF_CHUNK_SIZE translations in each block
	__shared__ XFLOAT s_outs[PROJDIFF_CHUNK_SIZE];
	// inside the padded 2D orientation gri
	if( bid < todo_blocks ) // we only need to make
	{
		unsigned trans_num   = d_job_num[bid]; //how many transes we have for this rot
		for (int itrans=0; itrans<trans_num; itrans++)
		{
			s[itrans*BLOCK_SIZE+tid] = 0.0f;
		}
		// index of comparison
		unsigned long int ix = d_rot_idx[d_job_idx[bid]];
		unsigned long int iy;
		unsigned pass_num(ceilf(   ((float)image_size) / (float)BLOCK_SIZE  ));

		for (unsigned pass = 0; pass < pass_num; pass++) // finish an entire ref image each block
		{
			pixel = (pass * BLOCK_SIZE) + tid;

			if(pixel < image_size)
			{
				int x = pixel % projector.imgX;
				int y = (int)floorf( (float)pixel / (float)projector.imgX);

				if (y > projector.maxR)
				{
					if (y >= projector.imgY - projector.maxR)
						y = y - projector.imgY;
					else
						x = projector.maxR;
				}

				if(do_3DProjection)
					projector.project3Dmodel(
						x,y,
						__ldg(&g_eulers[ix*9  ]), __ldg(&g_eulers[ix*9+1]),
						__ldg(&g_eulers[ix*9+3]), __ldg(&g_eulers[ix*9+4]),
						__ldg(&g_eulers[ix*9+6]), __ldg(&g_eulers[ix*9+7]),
						ref_real, ref_imag);
				else
					projector.project2Dmodel(
						x,y,
						__ldg(&g_eulers[ix*9  ]), __ldg(&g_eulers[ix*9+1]),
						__ldg(&g_eulers[ix*9+3]), __ldg(&g_eulers[ix*9+4]),
						__ldg(&g_eulers[ix*9+6]), __ldg(&g_eulers[ix*9+7]),
						ref_real, ref_imag);

				XFLOAT diff_real;
				XFLOAT diff_imag;
				for (int itrans=0; itrans<trans_num; itrans++) // finish all translations in each partial pass
				{
					iy=d_trans_idx[d_job_idx[bid]]+itrans;
					unsigned long img_start(iy * image_size);
					unsigned long img_pixel_idx = img_start + pixel;
					diff_real =  ref_real - __ldg(&g_imgs_real[img_pixel_idx]); // TODO  Put g_img_* in texture (in such a way that fetching of next image might hit in cache)
					diff_imag =  ref_imag - __ldg(&g_imgs_imag[img_pixel_idx]);
					s[itrans*BLOCK_SIZE + tid] += (diff_real * diff_real + diff_imag * diff_imag) * 0.5f * __ldg(&g_corr_img[pixel]);
				}
				__syncthreads();
			}
		}
		for(int j=(BLOCK_SIZE/2); j>0; j/=2)
		{
			if(tid<j)
			{
				for (int itrans=0; itrans<trans_num; itrans++) // finish all translations in each partial pass
				{
					s[itrans*BLOCK_SIZE+tid] += s[itrans*BLOCK_SIZE+tid+j];
				}
			}
			__syncthreads();
		}
		if (tid < trans_num)
		{
			s_outs[tid]=s[tid*BLOCK_SIZE]+sum_init;
		}
		if (tid < trans_num)
		{
			iy=d_job_idx[bid]+tid;
			g_diff2s[iy] = s_outs[tid];
		}
	}
}




/*
 *   	CROSS-CORRELATION-BASED KERNELS
 */

template<bool do_3DProjection>
__global__ void cuda_kernel_diff2_CC_coarse(
		XFLOAT *g_eulers,
		XFLOAT *g_imgs_real,
		XFLOAT *g_imgs_imag,
		CudaProjectorKernel projector,
		XFLOAT *g_corr_img,
		XFLOAT *g_diff2s,
		unsigned translation_num,
		int image_size,
		XFLOAT exp_local_sqrtXi2
		)
{
	int bid = blockIdx.y * gridDim.x + blockIdx.x;
	int tid = threadIdx.x;
	int shared_mid_size = translation_num*BLOCK_SIZE;

	XFLOAT ref_real;
	XFLOAT ref_imag;

	XFLOAT e0,e1,e3,e4,e6,e7;
	e0 = __ldg(&g_eulers[bid*9  ]);
	e1 = __ldg(&g_eulers[bid*9+1]);
	e3 = __ldg(&g_eulers[bid*9+3]);
	e4 = __ldg(&g_eulers[bid*9+4]);
	e6 = __ldg(&g_eulers[bid*9+6]);
	e7 = __ldg(&g_eulers[bid*9+7]);

	extern __shared__ XFLOAT s_cuda_kernel_diff2s[];

	for (unsigned i = 0; i < 2*translation_num; i++)
		s_cuda_kernel_diff2s[i*BLOCK_SIZE + tid] = 0.0f;
	__syncthreads();

	unsigned pixel_pass_num( ceilf( (float)image_size / (float)BLOCK_SIZE ) );
	for (unsigned pass = 0; pass < pixel_pass_num; pass++)
	{
		unsigned pixel = (pass * BLOCK_SIZE) + tid;

		if(pixel < image_size)
		{
			int x = pixel % projector.imgX;
			int y = (int)floorf( (float)pixel / (float)projector.imgX);

			if (y > projector.maxR)
			{
				if (y >= projector.imgY - projector.maxR)
					y = y - projector.imgY;
				else
					x = projector.maxR;
			}

			if(do_3DProjection)
				projector.project3Dmodel(
					x,y,
					e0,e1,e3,e4,e6,e7,
					ref_real, ref_imag);
			else
				projector.project2Dmodel(
					x,y,
					e0,e1,e3,e4,e6,e7,
					ref_real, ref_imag);

			for (int itrans = 0; itrans < translation_num; itrans ++)
			{
				unsigned long img_pixel_idx = itrans * image_size + pixel;

				XFLOAT diff_real =  ref_real * __ldg(&g_imgs_real[img_pixel_idx]);
				XFLOAT diff_imag =  ref_imag * __ldg(&g_imgs_imag[img_pixel_idx]);

				s_cuda_kernel_diff2s[translation_num * tid + itrans] += (diff_real + diff_imag) * __ldg(&g_corr_img[pixel]);
				s_cuda_kernel_diff2s[translation_num * tid + itrans + shared_mid_size] += (ref_real*ref_real + ref_imag*ref_imag ) * __ldg(&g_corr_img[pixel]);
			}
		}
	}

	__syncthreads();

	unsigned trans_pass_num( ceilf( (float)translation_num / (float)BLOCK_SIZE ) );
	for (unsigned pass = 0; pass < trans_pass_num; pass++)
	{
		unsigned itrans = (pass * BLOCK_SIZE) + tid;
		if (itrans < translation_num)
		{
			XFLOAT sum(0);
			XFLOAT cc_norm(0);
			for (unsigned i = 0; i < BLOCK_SIZE; i++)
			{
				sum     += s_cuda_kernel_diff2s[i * translation_num + itrans];
				cc_norm += s_cuda_kernel_diff2s[i * translation_num + itrans + shared_mid_size];
			}
			g_diff2s[bid * translation_num + itrans] = - sum /  (sqrt(cc_norm) );// * exp_local_sqrtXi2 );
		}
	}
}

template<bool do_3DProjection>
__global__ void cuda_kernel_diff2_CC_fine(
		XFLOAT *g_eulers,
		XFLOAT *g_imgs_real,
		XFLOAT *g_imgs_imag,
		CudaProjectorKernel projector,
		XFLOAT *g_corr_img,
		XFLOAT *g_diff2s,
		unsigned image_size,
		XFLOAT sum_init,
		XFLOAT exp_local_sqrtXi2,
		unsigned long orientation_num,
		unsigned long translation_num,
		unsigned long todo_blocks,
		unsigned long *d_rot_idx,
		unsigned long *d_trans_idx,
		unsigned long *d_job_idx,
		unsigned long *d_job_num
		)
{
	int bid = blockIdx.y * gridDim.x + blockIdx.x;
	int tid = threadIdx.x;

//    // Specialize BlockReduce for a 1D block of 128 threads on type XFLOAT
//    typedef cub::BlockReduce<XFLOAT, 128> BlockReduce;
//    // Allocate shared memory for BlockReduce
//    __shared__ typename BlockReduce::TempStorage temp_storage;

	int pixel;
	XFLOAT ref_real;
	XFLOAT ref_imag;

	__shared__ XFLOAT      s[BLOCK_SIZE*PROJDIFF_CHUNK_SIZE]; //We MAY have to do up to PROJDIFF_CHUNK_SIZE translations in each block
	__shared__ XFLOAT   s_cc[BLOCK_SIZE*PROJDIFF_CHUNK_SIZE];
	__shared__ XFLOAT s_outs[PROJDIFF_CHUNK_SIZE];

	if( bid < todo_blocks ) // we only need to make
	{
		unsigned trans_num   = d_job_num[bid]; //how many transes we have for this rot
		for (int itrans=0; itrans<trans_num; itrans++)
		{
			s[   itrans*BLOCK_SIZE+tid] = 0.0f;
			s_cc[itrans*BLOCK_SIZE+tid] = 0.0f;
		}
		__syncthreads();
		// index of comparison
		unsigned long int ix = d_rot_idx[d_job_idx[bid]];
		unsigned long int iy;
		unsigned pass_num(ceilf(   ((float)image_size) / (float)BLOCK_SIZE  ));

		for (unsigned pass = 0; pass < pass_num; pass++) // finish an entire ref image each block
		{
			pixel = (pass * BLOCK_SIZE) + tid;

			if(pixel < image_size)
			{
				int x = pixel % projector.imgX;
				int y = (int)floorf( (float)pixel / (float)projector.imgX);

				if (y > projector.maxR)
				{
					if (y >= projector.imgY - projector.maxR)
						y = y - projector.imgY;
					else
						x = projector.maxR;
				}
				if(do_3DProjection)
					projector.project3Dmodel(
						x,y,
						__ldg(&g_eulers[ix*9  ]), __ldg(&g_eulers[ix*9+1]),
						__ldg(&g_eulers[ix*9+3]), __ldg(&g_eulers[ix*9+4]),
						__ldg(&g_eulers[ix*9+6]), __ldg(&g_eulers[ix*9+7]),
						ref_real, ref_imag);
				else
					projector.project2Dmodel(
						x,y,
						__ldg(&g_eulers[ix*9  ]), __ldg(&g_eulers[ix*9+1]),
						__ldg(&g_eulers[ix*9+3]), __ldg(&g_eulers[ix*9+4]),
						__ldg(&g_eulers[ix*9+6]), __ldg(&g_eulers[ix*9+7]),
						ref_real, ref_imag);

				XFLOAT diff_real;
				XFLOAT diff_imag;
				for (int itrans=0; itrans<trans_num; itrans++) // finish all translations in each partial pass
				{
					iy=d_trans_idx[d_job_idx[bid]]+itrans;
					unsigned long img_start(iy * image_size);
					unsigned long img_pixel_idx = img_start + pixel;
					diff_real =  ref_real * __ldg(&g_imgs_real[img_pixel_idx]); // TODO  Put g_img_* in texture (in such a way that fetching of next image might hit in cache)
					diff_imag =  ref_imag * __ldg(&g_imgs_imag[img_pixel_idx]);
					s[   itrans*BLOCK_SIZE + tid] += (diff_real + diff_imag) * __ldg(&g_corr_img[pixel]);
					s_cc[itrans*BLOCK_SIZE + tid] += (ref_real*ref_real + ref_imag*ref_imag) * __ldg(&g_corr_img[pixel]);
				}
				__syncthreads();
			}
		}
		for(int j=(BLOCK_SIZE/2); j>0; j/=2)
		{
			if(tid<j)
			{
				for (int itrans=0; itrans<trans_num; itrans++) // finish all translations in each partial pass
				{
					s[   itrans*BLOCK_SIZE+tid] += s[   itrans*BLOCK_SIZE+tid+j];
					s_cc[itrans*BLOCK_SIZE+tid] += s_cc[itrans*BLOCK_SIZE+tid+j];
				}
			}
			__syncthreads();
		}
		if (tid < trans_num)
		{
			s_outs[tid]= - s[tid*BLOCK_SIZE] / (sqrt(s_cc[tid*BLOCK_SIZE]));// * exp_local_sqrtXi2 );
		}
		if (tid < trans_num)
		{
			iy=d_job_idx[bid]+tid;
			g_diff2s[iy] = s_outs[tid];
		}
	}
}
#endif /* CUDA_DIFF2_KERNELS_CUH_ */
