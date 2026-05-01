//**************************************************************************************************
// Type Redefinitions

typedef void v0;

#ifdef __cplusplus
#if defined __BORLANDC__
typedef bool b8;
#else
typedef unsigned char b8;
#endif
#else
typedef char b8;
#endif

typedef unsigned char u8;
typedef unsigned short u16;
typedef unsigned int u32;
#if defined _MSC_VER || defined __BORLANDC__
typedef unsigned __int64 u64;
#else
typedef unsigned long long int u64;
#endif

typedef char s8;
typedef short s16;
typedef int s32;
#if defined _MSC_VER || defined __BORLANDC__
typedef __int64 s64;
#else
typedef long long int s64;
#endif

typedef float f32;
typedef double f64;
typedef long double f80;

#if defined(_WIN64) || defined(__LP64__) || defined(__x86_64__) || defined(__aarch64__)
typedef u64 uptr;
typedef s64 sptr;
#else
typedef u32 uptr;
typedef s32 sptr;
#endif
