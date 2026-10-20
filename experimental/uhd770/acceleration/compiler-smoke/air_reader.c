/*
 * Decode Apple AIR bitcode through LLVM's C reader without creating a target
 * machine. Stock opt rejects the air64 architecture even when bitcode parsing
 * succeeds; the frontend only needs textual IR, with its original triple and
 * address-space layout preserved. This supplies its existing `air-opt -S ...
 * -o ...` fallback contract and never compiles or executes GPU instructions.
 */
#include <llvm-c/BitReader.h>
#include <llvm-c/Core.h>
#include <stdio.h>
#include <string.h>

static void diagnostic(LLVMDiagnosticInfoRef information, void *unused)
{
    (void)unused;
    char *message = LLVMGetDiagInfoDescription(information);
    if (message != NULL) {
        fprintf(stderr, "AIR reader: %s\n", message);
        LLVMDisposeMessage(message);
    }
}

int main(int argc, char **argv)
{
    if (argc != 5 || strcmp(argv[1], "-S") || strcmp(argv[3], "-o")) {
        fputs("Usage: air-opt -S input.air -o output.ll\n", stderr);
        return 2;
    }
    int result = 2;
    LLVMContextRef context = LLVMContextCreate();
    LLVMMemoryBufferRef buffer = NULL;
    LLVMModuleRef module = NULL;
    char *error = NULL;
    if (context == NULL) {
        fputs("AIR reader: context allocation failed\n", stderr);
        return result;
    }
    LLVMContextSetDiagnosticHandler(context, diagnostic, NULL);
    if (LLVMCreateMemoryBufferWithContentsOfFile(argv[2], &buffer, &error)) {
        fprintf(stderr, "AIR reader: %s\n", error ? error : "input read failed");
        goto cleanup;
    }
    if (LLVMParseBitcodeInContext2(context, buffer, &module)) {
        fputs("AIR reader: bitcode parse failed\n", stderr);
        goto cleanup;
    }
    if (LLVMPrintModuleToFile(module, argv[4], &error)) {
        fprintf(stderr, "AIR reader: %s\n", error ? error : "IR write failed");
        goto cleanup;
    }
    fprintf(stderr, "AIR reader: preserved target %s\n", LLVMGetTarget(module));
    result = 0;
cleanup:
    if (error != NULL) LLVMDisposeMessage(error);
    if (module != NULL) LLVMDisposeModule(module);
    if (buffer != NULL) LLVMDisposeMemoryBuffer(buffer);
    LLVMContextDispose(context);
    return result;
}
