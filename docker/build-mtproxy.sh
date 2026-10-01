#!/bin/sh
# Builds official MTProxy for the host architecture.
#
# Upstream MTProxy builds x86-only: its Makefile hardcodes -march=core2
# -mfpmath=sse -mssse3, and the SSE4.2/PCLMULQDQ fast paths are selected at
# runtime by CPUID. The generic table paths are portable C and always work, so
# this script drops the x86-only codegen flags on other architectures and lets
# the runtime CPUID probe select the portable path instead.
#
# The C sources are taken from the pinned upstream commit and patched with
# mtproxy-patches/*.patch, so a non-x86 build is reproducible from the same
# verified archive the x86 build uses.
#
# Usage: build-mtproxy.sh <source-dir> <output-dir> [patches-dir]
set -eu

source_directory="${1:?usage: build-mtproxy.sh <source-dir> <output-dir> [patches-dir]}"
output_directory="${2:?usage: build-mtproxy.sh <source-dir> <output-dir> [patches-dir]}"
patches_directory="${3:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/mtproxy-patches}"

arch=$(uname -m)
case "$arch" in
	x86_64 | amd64)
		# Upstream flags are correct here; use them verbatim.
		cflags_extra='-mpclmul -march=core2 -mfpmath=sse -mssse3'
		;;
	*)
		# -mpclmul, -mfpmath, -mssse3 and -march=core2 are all x86-only and
		# make the compiler reject the build. Everything else is portable.
		cflags_extra=''
		;;
esac

# -fno-strict-aliasing and friends matter to the packet parser; keep upstream's
# full warning and hardening set, only replacing the architecture flags.
base_cflags="-O3 -std=gnu11 -Wall -Wno-array-bounds -fno-strict-aliasing -fno-strict-overflow -fwrapv -DAES=1 -D_GNU_SOURCE=1 -D_FILE_OFFSET_BITS=64"
ldflags="-ggdb -rdynamic -lm -lrt -lcrypto -lz -lpthread -lcrypto"

if [ ! -f "$source_directory/Makefile" ]; then
	echo "build-mtproxy.sh: $source_directory does not look like an MTProxy tree" >&2
	exit 1
fi

for patch_file in "$patches_directory"/*.patch; do
	[ -e "$patch_file" ] || continue
	patch -d "$source_directory" -p1 --forward --silent <"$patch_file"
done

echo "build-mtproxy.sh: building MTProxy for $arch"
make -C "$source_directory" -j"$(nproc 2>/dev/null || echo 2)" \
	CFLAGS="$base_cflags $cflags_extra" \
	LDFLAGS="$ldflags"

binary="$source_directory/objs/bin/mtproto-proxy"
if [ ! -x "$binary" ]; then
	echo "build-mtproxy.sh: build produced no binary" >&2
	exit 1
fi

install -d "$output_directory"
install -m 0755 "$binary" "$output_directory/mtproto-proxy"
echo "build-mtproxy.sh: installed $output_directory/mtproto-proxy"
