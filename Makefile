clang ?= clang
compile = $(clang) -O3 -g

# broken atm
runtests: testsources/main_io_read testsources/main_ooo_read testsources/testrunbothorders.sh
	./testsources/testrunbothorders.sh

testsources/byrowbyrow: testsources/byrowbyrow.c
	$(compile) testsources/byrowbyrow.c -o testsources/byrowbyrow
testsources/byrowbycol: testsources/byrowbycol.c
	$(compile) testsources/byrowbycol.c -o testsources/byrowbycol
testsources/bycolbyrow: testsources/bycolbyrow.c
	$(compile) testsources/bycolbyrow.c -o testsources/bycolbyrow
testsources/bycolbycol: testsources/bycolbycol.c
	$(compile) testsources/bycolbycol.c -o testsources/bycolbycol

smallest: testsources/smallest_possible_io.ll

testsources/smallest_possible_io.ll:
	$(clang) -std=c11 -S -emit-llvm testsources/smallest_possible_io.c -o testsources/smallest_possible_io.ll
