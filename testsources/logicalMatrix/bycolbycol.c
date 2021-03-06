#include "stdio.h"
#include "stdlib.h"

typedef int intish;

typedef struct Matrix {
  int nrows;
  int ncols;
  intish* data;
} Matrix;

__attribute__ ((noinline))
Matrix multiply(Matrix A, Matrix B) {
  Matrix C = {A.nrows, B.ncols, (intish *) malloc(sizeof(intish) * A.nrows * B.ncols)};
  for(int column = 0; column < C.ncols; column++) {
    for(int row = 0; row < C.nrows; row++) {
      intish s = 0;
      for(int k = 0; k < A.ncols; k++) {
        intish a = A.data[k + row * A.ncols];
        intish b = B.data[k + column * B.nrows];
        int value = (a && b);
        if(value) {
          s = 1;
          break;
        }
        s = s || value;
      }
      C.data[column + row * C.ncols] = s;
    }
  }
  return C;
}

Matrix readMatrix(FILE *f) {
  int nrows, ncols;
  fscanf(f, "%d", &nrows);
  fscanf(f, "%d", &ncols);
  intish *data = (intish*) malloc(nrows * ncols * sizeof(intish));
  for(intish i = 0; i < nrows * ncols; i++) {
    fscanf(f, "%d", &data[i]);
  }
  Matrix r = {ncols, nrows, data};
  return r;
}

void printMatrix(Matrix matrix) {
  for(int i = 0; i < matrix.nrows; i++) {
    for(int j = 0; j < matrix.ncols; j++) {
      printf("%d ", matrix.data[j + i * matrix.ncols]);
    }
    printf("\n");
  }
}

int main() {
  FILE *f = fopen("logicalMatrixTestData", "r");
  Matrix A = readMatrix(f);
  Matrix B = readMatrix(f);
  fclose(f);
  puts("done reading");
  multiply(A, B);
}
