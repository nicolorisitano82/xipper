// Copyright (c) Meta Platforms, Inc. and affiliates.

#ifndef OPENZL_ZS2_CONFIG_H
#define OPENZL_ZS2_CONFIG_H

// clang-format off
// BEGIN CODEMOD DEFINES
#ifndef OPENZL_HAVE_X86_64_ASM
#define OPENZL_HAVE_X86_64_ASM ZL_HAVE_X86_64_ASM // TODO(T223464378): Delete
#endif
// END CODEMOD DEFINES
// clang-format on

#define ZL_ALLOW_INTROSPECTION 1

#define ZL_HAVE_X86_64_ASM 0

#endif
