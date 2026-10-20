; Hand-authored textual AIR fixture, not Apple-produced bitcode.
; Uses the v27 triple/metadata shape already exercised by
; translator/translator/tests/opencl_work_size.rs. This only tests translator ABI.
target triple = "air64_v27-apple-macosx15.7.0"

declare i32 @air.get_global_id.i32(i32)

define void @smoke(ptr addrspace(1) noalias %input, ptr addrspace(1) noalias %output) {
entry:
  %gid = call i32 @air.get_global_id.i32(i32 0)
  %index = zext i32 %gid to i64
  %src = getelementptr inbounds i32, ptr addrspace(1) %input, i64 %index
  %value = load i32, ptr addrspace(1) %src, align 4
  %mixed = xor i32 %value, 324508639
  %scaled = mul i32 %gid, 17
  %result = add i32 %mixed, %scaled
  %dst = getelementptr inbounds i32, ptr addrspace(1) %output, i64 %index
  store i32 %result, ptr addrspace(1) %dst, align 4
  ret void
}

!air.kernel = !{!0}
!0 = !{ptr @smoke, !1, !2}
!1 = !{}
!2 = !{!3, !4}
!3 = !{i32 0, !"air.buffer", !"air.location_index", i32 0, i32 1, !"air.read", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"input"}
!4 = !{i32 1, !"air.buffer", !"air.location_index", i32 1, i32 1, !"air.write", !"air.address_space", i32 1, !"air.arg_type_size", i32 4, !"air.arg_type_align_size", i32 4, !"air.arg_type_name", !"uint", !"air.arg_name", !"output"}
