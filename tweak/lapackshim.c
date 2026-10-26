// ATLAS-style clapack C wrappers over Fortran LAPACK (libLAPACK.dylib on iOS 6).
// RowMajor is handled via transposition; Kaldi primarily uses ColMajor.
#include <stdlib.h>
#define CblasRowMajor 101
#define CblasColMajor 102

void dgetrf_(int *m, int *n, double *a, int *lda, int *ipiv, int *info);
void dgetri_(int *n, double *a, int *lda, int *ipiv, double *work, int *lwork, int *info);
void sgetrf_(int *m, int *n, float *a, int *lda, int *ipiv, int *info);
void sgetri_(int *n, float *a, int *lda, int *ipiv, float *work, int *lwork, int *info);
void dtrtri_(char *uplo, char *diag, int *n, double *a, int *lda, int *info, size_t u, size_t d);
void strtri_(char *uplo, char *diag, int *n, float *a, int *lda, int *info, size_t u, size_t d);

static void tr_r2cd(int m, int n, const double *s, int lds, double *d, int ldd) {
    for (int j = 0; j < n; j++) for (int i = 0; i < m; i++) d[(size_t)j*ldd+i] = s[(size_t)i*lds+j];
}
static void tr_c2rd(int m, int n, const double *s, int lds, double *d, int ldd) {
    for (int j = 0; j < n; j++) for (int i = 0; i < m; i++) d[(size_t)i*ldd+j] = s[(size_t)j*lds+i];
}
static void trf_r2cf(int m, int n, const float *s, int lds, float *d, int ldd) {
    for (int j = 0; j < n; j++) for (int i = 0; i < m; i++) d[(size_t)j*ldd+i] = s[(size_t)i*lds+j];
}
static void trf_c2rf(int m, int n, const float *s, int lds, float *d, int ldd) {
    for (int j = 0; j < n; j++) for (int i = 0; i < m; i++) d[(size_t)i*ldd+j] = s[(size_t)j*lds+i];
}

int clapack_dgetrf(int order, int m, int n, double *a, int lda, int *ipiv) {
    if (order == CblasRowMajor) {
        double *c = (double *)malloc((size_t)m*n*8);
        tr_r2cd(m, n, a, lda, c, m);
        int info; void dgetrf_(int*,int*,double*,int*,int*,int*);
        int mm = n, nn = m, l = m; dgetrf_(&mm,&nn,c,&l,ipiv,&info);
        tr_c2rd(n, m, c, m, a, lda); free(c); return info;
    }
    int info; dgetrf_(&m,&n,a,&lda,ipiv,&info); return info;
}
int clapack_dgetri(int order, int n, double *a, int lda, int *ipiv) {
    if (order == CblasRowMajor) {
        double *c = (double *)malloc((size_t)n*n*8);
        tr_r2cd(n, n, a, lda, c, n);
        int info; void dgetri_(int*,double*,int*,int*,double*,int*,int*);
        int work = n*n; double *w = (double *)malloc((size_t)work*8);
        int nn = n, l = n; dgetri_(&nn,c,&l,ipiv,w,&work,&info);
        tr_c2rd(n, n, c, n, a, lda); free(c); free(w); return info;
    }
    int info; int work = n*n; double *w = (double *)malloc((size_t)work*8);
    void dgetri_(int*,double*,int*,int*,double*,int*,int*);
    dgetri_(&n,a,&lda,ipiv,w,&work,&info); free(w); return info;
}
int clapack_sgetrf(int order, int m, int n, float *a, int lda, int *ipiv) {
    if (order == CblasRowMajor) {
        float *c = (float *)malloc((size_t)m*n*4);
        trf_r2cf(m, n, a, lda, c, m);
        int info; void sgetrf_(int*,int*,float*,int*,int*,int*);
        int mm = n, nn = m, l = m; sgetrf_(&mm,&nn,c,&l,ipiv,&info);
        trf_c2rf(n, m, c, m, a, lda); free(c); return info;
    }
    int info; sgetrf_(&m,&n,a,&lda,ipiv,&info); return info;
}
int clapack_sgetri(int order, int n, float *a, int lda, int *ipiv) {
    if (order == CblasRowMajor) {
        float *c = (float *)malloc((size_t)n*n*4);
        trf_r2cf(n, n, a, lda, c, n);
        int info; void sgetri_(int*,float*,int*,int*,float*,int*,int*);
        int work = n*n; float *w = (float *)malloc((size_t)work*4);
        int nn = n, l = n; sgetri_(&nn,c,&l,ipiv,w,&work,&info);
        trf_c2rf(n, n, c, n, a, lda); free(c); free(w); return info;
    }
    int info; int work = n*n; float *w = (float *)malloc((size_t)work*4);
    void sgetri_(int*,float*,int*,int*,float*,int*,int*);
    sgetri_(&n,a,&lda,ipiv,w,&work,&info); free(w); return info;
}
int clapack_dtrtri(int order, int uplo, int diag, int n, double *a, int lda) {
    if (order == CblasRowMajor) {
        double *c = (double *)malloc((size_t)n*n*8);
        tr_r2cd(n, n, a, lda, c, n);
        int info; void dtrtri_(char*,char*,int*,double*,int*,int*,size_t,size_t);
        char u = uplo==121?'U':'L', dg = diag==131?'U':'N';
        int nn = n, l = n; dtrtri_(&u,&dg,&nn,c,&l,&info,1,1);
        tr_c2rd(n, n, c, n, a, lda); free(c); return info;
    }
    int info; void dtrtri_(char*,char*,int*,double*,int*,int*,size_t,size_t);
    char u = uplo==121?'U':'L', dg = diag==131?'U':'N';
    dtrtri_(&u,&dg,&n,a,&lda,&info,1,1); return info;
}
int clapack_strtri(int order, int uplo, int diag, int n, float *a, int lda) {
    if (order == CblasRowMajor) {
        float *c = (float *)malloc((size_t)n*n*4);
        trf_r2cf(n, n, a, lda, c, n);
        int info; void strtri_(char*,char*,int*,float*,int*,int*,size_t,size_t);
        char u = uplo==121?'U':'L', dg = diag==131?'U':'N';
        int nn = n, l = n; strtri_(&u,&dg,&nn,c,&l,&info,1,1);
        trf_c2rf(n, n, c, n, a, lda); free(c); return info;
    }
    int info; void strtri_(char*,char*,int*,float*,int*,int*,size_t,size_t);
    char u = uplo==121?'U':'L', dg = diag==131?'U':'N';
    strtri_(&u,&dg,&n,a,&lda,&info,1,1); return info;
}
