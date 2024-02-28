all:
	nasm -felf64 -o bfai.o bfai.asm
	ld -o bfai bfai.o
	rm bfai.o
