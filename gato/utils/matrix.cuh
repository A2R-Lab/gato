
#pragma once
#include <cstdint>

#include "gato.cuh"
#include "GBD-PCG/include/utils.cuh" // TODO: GBD-PCG utils include fix

/**
 * @brief Performs matrix-vector multiplication A^T * x.
 */
template <typename T>
__device__
void gato_ATx(T *out, T *mat, T *vec, int m, int n){

    T res;
    int ind, thing;

    for(ind=threadIdx.x; ind < n; ind +=blockDim.x){

        res = 0;
        for(thing=0; thing<m; thing++){
            res += mat[ind*m+thing] * vec[thing];
        }

        out[ind] = res;
    }
}

/**
 * @brief Computes the element-wise difference between two vectors.
 */
template <typename T>
__device__
void gato_vec_dif(T *out, T *vec1, T *vec2, int size){
    for(int i = threadIdx.x; i < size; i+= blockDim.x){
        out[i] = vec1[i] - vec2[i];
    }
}

/**
 * @brief Computes the element-wise sum of two vectors.
 */
template <typename T>
__device__
void gato_vec_sum(T *out, T *vec1, T *vec2, int size){
    for(int i = threadIdx.x; i < size; i+= blockDim.x){
        out[i] = vec1[i] + vec2[i];
    }
}

/**
 * @brief Matrix-vector multiplication.
 */
template <typename T>
__device__
void mat_vec_prod(unsigned MAT_ROWS, unsigned MAT_COLS, T *mat, T *vec, T *out){
    
    for(unsigned row=threadIdx.x; row<MAT_ROWS; row+=blockDim.x){
        T res = static_cast<T>(0);
        for (unsigned col = 0; col < MAT_COLS; col++){
            res += mat[row + col*MAT_ROWS] * vec[col];
        }
        out[row] = res;
    }
}

/**
 * @brief Add a scaled identity matrix to an existing matrix
 */
template <typename T>
__device__
void add_identity(T *A, unsigned dim, T factor){
    for(unsigned i = threadIdx.x; i < dim*dim; i+=blockDim.x){
        if(i/dim == i%dim){ A[i] += factor; }
    }
}


// load identity in so memory is [A | I]
template <typename T>
__device__ __forceinline__
void loadIdentity(uint32_t DIM, T *A){
    for (unsigned ind = threadIdx.x; ind < DIM*DIM; ind += blockDim.x){
        unsigned r, c;
        r = ind % DIM; 
        c = ind / DIM;
        A[ind] = static_cast<T>(r == c);
    }
}

// load identity in so memory is [V | I]
template <typename T>
__device__ __forceinline__
void loadIdentity(uint32_t DIMA, uint32_t DIMB, T *A, T *B){
    for (unsigned ind = threadIdx.x; ind < DIMA*DIMA+DIMB*DIMB; ind += blockDim.x){
        unsigned r, c, indAdj; T *V;
        if (ind < DIMA*DIMA){
            indAdj = ind;
            r = indAdj % DIMA; c = indAdj/DIMA; V = A;
        }
        else {
            indAdj = ind - DIMA*DIMA;
            r = indAdj % DIMB; c = indAdj/DIMB; V = B;
        }
        V[indAdj] = static_cast<T>(r == c);
    }
}


// load identity in so memory is [V | I]
template <typename T>
__device__ __forceinline__
void loadIdentity(unsigned DIMA, unsigned DIMB, unsigned DIMC, T *A, T *B, T *C){
    for (unsigned ind = threadIdx.x; ind < DIMA*DIMA+DIMB*DIMB+DIMC*DIMC; ind += blockDim.x){
        unsigned r, c, indAdj; T *V;
        if (ind < DIMA*DIMA){
            indAdj = ind;
            r = indAdj % DIMA; c = indAdj/DIMA; V = A;
        }
        else if (ind < DIMA*DIMA+DIMB*DIMB){
            indAdj = ind - DIMA*DIMA;
            r = indAdj % DIMB; c = indAdj/DIMB; V = B;
        }
        else{
            indAdj = ind - DIMA*DIMA - DIMB*DIMB;
            r = indAdj % DIMC; c = indAdj/DIMC; V = C;
        }
        V[indAdj] = static_cast<T>(r == c);
    }
}

/**
 * @brief Inverts a square matrix using Gaussian elimination
 *
 * @tparam T The data type of the matrix elements
 * @param DIM The dimension of the square matrix
 * @param A The input/output matrix
 * @param s_temp Temporary shared memory for calculations
 */
template <typename T>
__device__
void invertMatrix(uint32_t DIM, T *A, T *s_temp){ 
// we are going to guassian elimination walking down the matrix (assuming no leading 0s)
// we therefore use the columns in order as the pivot column for each pivot we need to rescale 
// that row so that the pivot value (pv) is 1 THEN for all other row values (orv) we need to add a multiple 
// of the NEW pivot row value (prv) such that we transorm the other row pivot column value (orpcv) to 0
// pr *= 1/pv   orv -= orpcv*prv == orv -= orpcv*1/pv*prvOld
    for (unsigned pivRC = 0; pivRC < DIM; pivRC++){
        unsigned pivColOffset = pivRC*DIM;
        // save the pivot and pivot column and row
        T pvInv = static_cast<T>(1)/A[pivRC + pivColOffset];
        for (unsigned ind = threadIdx.x; ind < 2*DIM+1; ind++){
            unsigned AInd;
            if (ind < DIM){AInd = ind + pivColOffset;}
            else{AInd = pivRC + pivColOffset + (ind-DIM)*DIM;}
            s_temp[ind] = A[AInd];
        }
        __syncthreads(); //----------------------
        // make the pivot update
        for (unsigned ind = threadIdx.x; ind < DIM*(DIM+1); ind += blockDim.x){
            unsigned row = ind % DIM; unsigned col = ind / DIM; unsigned colOffset = ind - row;
            // s_temp = orpcvs|prvOld
            if (row == pivRC){A[row + pivColOffset + colOffset] *= pvInv;}
            else{A[row + pivColOffset + colOffset] -= s_temp[row]*pvInv*s_temp[DIM+col];}
        }
    __syncthreads(); //----------------------
    }
}


template <typename T>
__device__
void invertMatrix(unsigned DIMA, unsigned DIMB, unsigned MAX_DIM, T *A, T *B, T *s_temp){

    // now we are going to guassian elimination walking down the matrix (assuming no leading 0s)
    // we therefore use the columns in order as the pivot column for each pivot we need to rescale 
    // that row so that the pivot value (pv) is 1 THEN for all other row values (orv) we need to add a multiple 
    // of the NEW pivot row value (prv) such that we transorm the other row pivot column value (orpcv) to 0
    // pr *= 1/pv   orv -= orpcv*prv == orv -= orpcv*1/pv*prvOld
    T *s_memA = s_temp; T *s_memB = &s_memA[2*DIMA+1];
    for (unsigned pivRC = 0; pivRC < MAX_DIM; pivRC++){
        bool AActive = pivRC < DIMA; bool BActive = pivRC < DIMB;
        unsigned pivColOffsetA = pivRC*DIMA; unsigned pivColOffsetB = pivRC*DIMB;
        // save the pivot column and row
        for (unsigned ind = threadIdx.x; ind < MAX_DIM; ind++){
            if (AActive && ind < DIMA){s_memA[ind] = A[ind + pivColOffsetA];}
            if (BActive && ind < DIMB){s_memB[ind] = B[ind + pivColOffsetB];}
        }
        for (unsigned ind = threadIdx.x; ind < MAX_DIM+1; ind++){
            if (AActive && ind < DIMA+1){s_memA[ind + DIMA] = A[ind*DIMA + pivRC + pivColOffsetA];}
            if (BActive && ind < DIMB+1){s_memB[ind + DIMB] = B[ind*DIMB + pivRC + pivColOffsetB];}
        }
        __syncthreads(); //----------------------
        // make the pivot update with s_mem = [colA,rowA,colB,rowB,colC,rowC]
        for (unsigned ind = threadIdx.x; ind < MAX_DIM*(MAX_DIM+1); ind += blockDim.x){
            if (AActive && ind < DIMA*(DIMA+1)){
                unsigned row = ind % DIMA; unsigned col = ind / DIMA;
                if (row == pivRC){A[pivColOffsetA + ind] /= s_memA[pivRC];}
                else{A[pivColOffsetA + ind] -= s_memA[row]/s_memA[pivRC]*s_memA[DIMA+col];}
            }
            if (BActive && ind < DIMB*(DIMB+1)){
                unsigned row = ind % DIMB; unsigned col = ind / DIMB; 
                if (row == pivRC){B[pivColOffsetB + ind] /= s_memB[pivRC];}
                else{B[pivColOffsetB + ind] -= s_memB[row]/s_memB[pivRC]*s_memB[DIMB+col];}
            }
        }
        __syncthreads(); //----------------------
    }
}

// invert A,B,C assume memory for all is [V | VInv] where both are DIMxDIM and continguous
// relies on s_temp of size [2*DIMA + 2*DIMB + 2*DIMC + 3]
template <typename T>
__device__
void invertMatrix(unsigned DIMA, unsigned DIMB, unsigned DIMC, unsigned MAX_DIM, T *A, T *B, T *C, T *s_temp){

    // now we are going to guassian elimination walking down the matrix (assuming no leading 0s)
    // we therefore use the columns in order as the pivot column for each pivot we need to rescale 
    // that row so that the pivot value (pv) is 1 THEN for all other row values (orv) we need to add a multiple 
    // of the NEW pivot row value (prv) such that we transorm the other row pivot column value (orpcv) to 0
    // pr *= 1/pv   orv -= orpcv*prv == orv -= orpcv*1/pv*prvOld
    T *s_memA = s_temp; T *s_memB = &s_memA[2*DIMA+1]; T *s_memC = &s_memB[2*DIMB+1];
    for (unsigned pivRC = 0; pivRC < MAX_DIM; pivRC++){
        bool AActive = pivRC < DIMA; bool BActive = pivRC < DIMB; bool CActive = pivRC < DIMC;
        unsigned pivColOffsetA = pivRC*DIMA; unsigned pivColOffsetB = pivRC*DIMB; unsigned pivColOffsetC = pivRC*DIMC;
        // save the pivot column and row
        for (unsigned ind = threadIdx.x; ind < MAX_DIM; ind++){
            if (AActive && ind < DIMA){s_memA[ind] = A[ind + pivColOffsetA];}
            if (BActive && ind < DIMB){s_memB[ind] = B[ind + pivColOffsetB];}
            if (CActive && ind < DIMC){s_memC[ind] = C[ind + pivColOffsetC];}
        }
        for (unsigned ind = threadIdx.x; ind < MAX_DIM+1; ind++){
            if (AActive && ind < DIMA+1){s_memA[ind + DIMA] = A[ind*DIMA + pivRC + pivColOffsetA];}
            if (BActive && ind < DIMB+1){s_memB[ind + DIMB] = B[ind*DIMB + pivRC + pivColOffsetB];}
            if (CActive && ind < DIMC+1){s_memC[ind + DIMC] = C[ind*DIMC + pivRC + pivColOffsetC];}
        }
        __syncthreads(); //----------------------
        // make the pivot update with s_mem = [colA,rowA,colB,rowB,colC,rowC]
        for (unsigned ind = threadIdx.x; ind < MAX_DIM*(MAX_DIM+1); ind += blockDim.x){
            if (AActive && ind < DIMA*(DIMA+1)){
                unsigned row = ind % DIMA; unsigned col = ind / DIMA;
                if (row == pivRC){A[pivColOffsetA + ind] /= s_memA[pivRC];}
                else{A[pivColOffsetA + ind] -= s_memA[row]/s_memA[pivRC]*s_memA[DIMA+col];}
            }
            if (BActive && ind < DIMB*(DIMB+1)){
                unsigned row = ind % DIMB; unsigned col = ind / DIMB; 
                if (row == pivRC){B[pivColOffsetB + ind] /= s_memB[pivRC];}
                else{B[pivColOffsetB + ind] -= s_memB[row]/s_memB[pivRC]*s_memB[DIMB+col];}
            }
            if (CActive && ind < DIMC*(DIMC+1)){
                unsigned row = ind % DIMC; unsigned col = ind / DIMC;
                if (row == pivRC){C[pivColOffsetC + ind] /= s_memC[pivRC];}
                else{C[pivColOffsetC + ind] -= s_memC[row]/s_memC[pivRC]*s_memC[DIMC+col];}
            }
        }
        __syncthreads(); //----------------------
    }
}

// Write a matrix on device memory to a file
__host__
void write_device_matrix_to_file(float* d_matrix, int rows, int cols, const char* filename, int filesuffix) {
    
    char fname[100];
    snprintf(fname, sizeof(fname), "%s%d.txt", filename, filesuffix);
    
    // Allocate host memory for the matrix
    float* h_matrix = new float[rows * cols];

    // Copy the data from the device to the host memory
    size_t pitch = cols * sizeof(float);
    cudaMemcpy2D(h_matrix, pitch, d_matrix, pitch, pitch, rows, cudaMemcpyDeviceToHost);

    // Write the data to a file in column-major order
    std::ofstream outfile(fname);
    if (outfile.is_open()) {
        for (int row = 0; row < rows; ++row) {
            for (int col = 0; col < cols; ++col) {
                outfile << std::setprecision(std::numeric_limits<float>::max_digits10+1) << h_matrix[col * rows + row] << "\t";
            }
            outfile << std::endl;
        }
        outfile.close();
    } else {
        std::cerr << "Unable to open file: " << fname << std::endl;
    }

    // Deallocate host memory
    delete[] h_matrix;
}