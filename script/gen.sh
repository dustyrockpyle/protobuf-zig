# args: -I examples examples/file.proto
# set -ex
DEST_DIR=gen

dir=${dir%/*}
CMD="zig-out/bin/protoc-zig --zig_out=$DEST_DIR $@"
echo $CMD
$($CMD)
