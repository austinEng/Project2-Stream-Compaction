#include <cuda.h>
#include <cuda_runtime.h>
#include "common.h"
#include "efficient.h"

__global__ void printArr(int n, const int* data) {
  printf("    [ ");
  for (int i = 0; i < n; ++i) {
    printf("%3d ", data[i]);
  }
  printf("]\n");
}

namespace StreamCompaction {
namespace Efficient {

__global__ void scan_up(int n, int pow2d, int *odata, const int *idata) {
  int index = 2 * pow2d * (blockIdx.x * blockDim.x + threadIdx.x + 1) - 1;
  if (index >= n) return;
  odata[index] = idata[index - pow2d] + idata[index];
}

__global__ void scan_down(int n, int pow2d, int *odata, const int *idata) {
  int index = n - 2 * pow2d * (blockIdx.x * blockDim.x + threadIdx.x) - 1;
  if (index < 0) return;

  int temp = idata[index - pow2d];
  odata[index - pow2d] = idata[index];
  odata[index] = temp + idata[index];
}

__global__ void zero(int n, int *odata) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < 0) return;
  odata[index] = 0;
}

/**
 * Performs prefix-sum (aka scan) on idata, storing the result into odata.
 */
void scan(int n, int *odata, const int *idata) {
  int* dev_data;
  int sizePow2 = pow(2, ilog2ceil(n));

  const int blockSize = 128;
  int nBlocks;

  cudaMalloc((void**)&dev_data, sizePow2 * sizeof(int));
  checkCUDAError("cudaMalloc dev_data failed!");

  // fill with 0
  nBlocks = (sizePow2 + blockSize - 1) / blockSize;
  zero << <nBlocks, blockSize >> >(sizePow2, dev_data);

  cudaMemcpy(dev_data, idata, sizeof(int) * n, cudaMemcpyHostToDevice);
  checkCUDAError("cudaMemcpy from idata to dev_data failed!");

  // scan up
  for (int pow2d = 1, int threads = sizePow2; pow2d < sizePow2 / 2; pow2d *= 2, threads /= 2) {
    nBlocks = (threads + blockSize - 1) / blockSize; // threads / blockSize, rounded up
    scan_up << < nBlocks, threads >> >(n, pow2d, dev_data, dev_data);
  }

  // set last item to 0
  int zero = 0;
  cudaMemcpy(&dev_data[sizePow2 - 1], &zero, sizeof(int), cudaMemcpyHostToDevice);
  checkCUDAError("cudaMemcpy copy zero failed!");

  // scan down
  for (int pow2d = pow(2, ilog2ceil(sizePow2) - 1), int threads = 1; pow2d >= 1; pow2d /= 2, threads *= 2) {
    nBlocks = (threads + blockSize - 1) / blockSize; // threads / blockSize, rounded up
    scan_down << < nBlocks, threads >> >(sizePow2, pow2d, dev_data, dev_data);
  }

  cudaMemcpy(odata, dev_data, sizeof(int) * n, cudaMemcpyDeviceToHost);
  checkCUDAError("cudaMemcpy from dev_data to odata failed!");

  cudaFree(dev_data);
  checkCUDAError("cudaFree dev_data failed!");
}


__global__ void filter(int n, int *odata, const int* idata) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= n) return;
  odata[index] = idata[index] != 0;
}

__global__ void scatter(int n, int *odata, const int* idata, const int* mask, const int* indicies) {
  int index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index >= n) return;
  if (mask[index]) {
    odata[indicies[index]] = idata[index];
  }
}

/**
 * Performs stream compaction on idata, storing the result into odata.
 * All zeroes are discarded.
 *
 * @param n      The number of elements in idata.
 * @param odata  The array into which to store elements.
 * @param idata  The array of elements to compact.
 * @returns      The number of elements remaining after compaction.
 */
int compact(int n, int *odata, const int *idata) {
  int* dev_idata;
  int* dev_odata;
  int* dev_mask;
  int sizePow2 = pow(2, ilog2ceil(n));

  const int blockSize = 128;
  int nBlocks;

  cudaMalloc((void**)&dev_idata, n * sizeof(int));
  checkCUDAError("cudaMalloc dev_idata failed!");

  cudaMalloc((void**)&dev_odata, n * sizeof(int));
  checkCUDAError("cudaMalloc dev_odata failed!");

  cudaMalloc((void**)&dev_mask, sizePow2 * sizeof(int));
  checkCUDAError("cudaMalloc dev_idata failed!");

  cudaMemcpy(dev_idata, idata, sizeof(int) * n, cudaMemcpyHostToDevice);
  checkCUDAError("cudaMemcpy from idata to dev_data failed!");

  // printArr << <1, 1 >> >(n, dev_idata);

  // create mask
  nBlocks = (n + blockSize - 1) / blockSize;
  filter << <nBlocks, blockSize >> >(n, dev_mask, dev_idata);
  
  // save the mask here for usage later
  cudaMemcpy(dev_odata, dev_mask, sizeof(int) * n, cudaMemcpyDeviceToDevice);
  checkCUDAError("cudaMemcpy from dev_mask to dev_odata failed!");

  // printArr << <1, 1 >> >(n, dev_mask);
  
  int endsWith1;
  cudaMemcpy(&endsWith1, &dev_mask[n - 1], sizeof(int), cudaMemcpyDeviceToHost);
  checkCUDAError("cudaMemcpy copy to endswith1 failed!");

  // scan up
  for (int pow2d = 1, int threads = sizePow2; pow2d < sizePow2 / 2; pow2d *= 2, threads /= 2) {
    nBlocks = (threads + blockSize - 1) / blockSize; // threads / blockSize, rounded up
    scan_up << < nBlocks, threads >> >(n, pow2d, dev_mask, dev_mask);
  }

  // set last item to 0
  int last = 0;
  cudaMemcpy(&dev_mask[sizePow2 - 1], &last, sizeof(int), cudaMemcpyHostToDevice);
  checkCUDAError("cudaMemcpy copy zero failed!");

  // scan down
  for (int pow2d = pow(2, ilog2ceil(sizePow2) - 1), int threads = 1; pow2d >= 1; pow2d /= 2, threads *= 2) {
    nBlocks = (threads + blockSize - 1) / blockSize; // threads / blockSize, rounded up
    scan_down << < nBlocks, threads >> >(sizePow2, pow2d, dev_mask, dev_mask);
  }

  // copy back last val so we know how many elements
  cudaMemcpy(&last, &dev_mask[sizePow2 - 1], sizeof(int), cudaMemcpyDeviceToHost);
  checkCUDAError("cudaMemcpy copy last failed!");
  last += endsWith1; // increment if we should include the very last element

  // printArr << <1, 1 >> >(n, dev_mask);

  // scatter
  nBlocks = (n + blockSize - 1) / blockSize;
  scatter << <nBlocks, blockSize >> >(n , dev_odata, dev_idata, dev_odata, dev_mask);

  cudaMemcpy(odata, dev_odata, sizeof(int) * last, cudaMemcpyDeviceToHost);
  checkCUDAError("cudaMemcpy from dev_odata to odata failed!");

  cudaFree(dev_idata);
  checkCUDAError("cudaFree dev_idata failed!");

  cudaFree(dev_odata);
  checkCUDAError("cudaFree dev_odata failed!");

  cudaFree(dev_mask);
  checkCUDAError("cudaFree dev_mask failed!");

  return last;
}

}
}
