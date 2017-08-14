if [ -z "$BASH" ]; then
    ECHO=echo
else
    ECHO='echo -e'
fi
# NOTE: This requires GNU getopt.  On Mac OS X and FreeBSD, you have to install this
# separately; see below.
TEMP=`getopt -o v: --long incs:,libs:,cc:,cxx: -n 'config_brpc' -- "$@"`

if [ $? != 0 ] ; then >&2 $ECHO "Terminating..."; exit 1 ; fi

# Note the quotes around `$TEMP': they are essential!
eval set -- "$TEMP"

# Convert to abspath always so that generated mk is include-able from everywhere
CC=gcc
CXX=g++
while true; do
    case "$1" in
        --incs ) INCS="$(readlink -f $2)"; shift 2 ;;
        --libs ) LIBS="$(readlink -f $2)"; shift 2 ;;
        --cc ) CC=$2; shift 2 ;;
        --cxx ) CXX=$2; shift 2 ;;
        -- ) shift; break ;;
        * ) break ;;
    esac
done

if [ -z "$INCS" ] || [ -z "$LIBS" ]; then
    >&2 $ECHO "config_brpc: --incs=INCPATHS --libs=LIBPATHS must be specified"
    exit 1
fi

find_dir_of_lib() {
    local lib=$(find ${LIBS} -name "lib${1}.a" -o -name "lib${1}.so*" | head -n1)
    if [ ! -z "$lib" ]; then
        dirname $lib
    fi
}
find_dir_of_lib_or_die() {
    local dir=$(find_dir_of_lib $1)
    if [ -z "$dir" ]; then
        >&2 $ECHO "fail to find $1 from -libs"
        exit 1
    else
        $ECHO $dir
    fi
}

find_bin() {
    find ${LIBS} -name "$1" | head -n1
}

find_dir_of_header() {
    find ${INCS} -path "*/$1" | head -n1 | sed "s|$1||g"
}
find_dir_of_header_or_die() {
    local dir=$(find_dir_of_header $1)
    if [ -z "$dir" ]; then
        >&2 $ECHO "fail to find $1 from -incs"
        exit 1
    else
        $ECHO $dir
    fi
}

STATIC_LINKING=
DYNAMIC_LINKING="-lpthread -lrt -lssl -lcrypto -ldl -lz"
append_linking() {
    if [ -f $1/lib${2}.a ]; then
        STATIC_LINKING="${STATIC_LINKING} -l$2"
    else
        DYNAMIC_LINKING="${DYNAMIC_LINKING} -l$2"
    fi
}

GFLAGS_DIR=$(find_dir_of_lib_or_die gflags)
append_linking $GFLAGS_DIR gflags
PROTOBUF_DIR=$(find_dir_of_lib_or_die protobuf)
append_linking $PROTOBUF_DIR protobuf
PROTOC_DIR=$(find_dir_of_lib_or_die protoc)
LEVELDB_DIR=$(find_dir_of_lib_or_die leveldb)
append_linking $LEVELDB_DIR leveldb
# required by leveldb
SNAPPY_DIR=$(find_dir_of_lib snappy)
if [ ! -z "$SNAPPY_DIR" ]; then
    append_linking $SNAPPY_DIR snappy
fi

PROTOC=$(which protoc 2>/dev/null)
if [ -z "$PROTOC" ]; then
    PROTOC=$(find_bin protoc)
    if [ -z "$PROTOC" ]; then
        >&2 $ECHO "Fail to find protoc"
        exit 1
    fi
fi

GFLAGS_INC=$(find_dir_of_header gflags/gflags.h)
PROTOBUF_INC=$(find_dir_of_header google/protobuf/message.h)
LEVELDB_INC=$(find_dir_of_header leveldb/db.h)

INCS2=$($ECHO "$GFLAGS_INC\n$PROTOBUF_INC\n$LEVELDB_INC" | sort | uniq)
LIBS2=$($ECHO "$GFLAGS_DIR\n$PROTOBUF_DIR\n$LEVELDB_DIR\n$SNAPPY_DIR\n$PROTOC_DIR" | sort | uniq)

absent_in_the_list() {
    TMP=$($ECHO "`$ECHO "$1\n$2" | sort | uniq`")
    if [ "${TMP}" = "$2" ]; then
        return 1
    fi
    return 0
}

#can't use \n in texts because sh does not support -e
CONTENT="INCS=$($ECHO $INCS2)"
CONTENT="${CONTENT}\nLIBS=$($ECHO $LIBS2)"
CONTENT="${CONTENT}\nPROTOC=$PROTOC"
CONTENT="${CONTENT}\nPROTOBUF_INC=$PROTOBUF_INC"
CONTENT="${CONTENT}\nCC=$CC"
CONTENT="${CONTENT}\nCXX=$CXX"
CONTENT="${CONTENT}\nSTATIC_LINKING=$STATIC_LINKING"
CONTENT="${CONTENT}\nDYNAMIC_LINKING=$DYNAMIC_LINKING"
CONTENT="${CONTENT}\nifeq (\$(LINK_PERFTOOLS), 1)"
# required by cpu/heap profiler
TCMALLOC_DIR=$(find_dir_of_lib tcmalloc_and_profiler)
if [ ! -z "$TCMALLOC_DIR" ]; then
    if absent_in_the_list "$TCMALLOC_DIR" "$LIBS2"; then
        CONTENT="${CONTENT}\n    LIBS+=$TCMALLOC_DIR"
        LIBS2="${LIBS2}\n$TCMALLOC_DIR"
    fi
    TCMALLOC_INC=$(find_dir_of_header google/tcmalloc.h)
    if absent_in_the_list "$TCMALLOC_INC" "$INCS2"; then
        CONTENT="${CONTENT}\n    INCS+=$TCMALLOC_INC"
        INCS2="${INCS2}\n$TCMALLOC_INC"
    fi
    if [ -f $TCMALLOC_DIR/libtcmalloc_and_profiler.a ]; then
        CONTENT="${CONTENT}\n    STATIC_LINKING+=-ltcmalloc_and_profiler"
    else
        CONTENT="${CONTENT}\n    DYNAMIC_LINKING+=-ltcmalloc_and_profiler"
    fi
fi
# required by tcmalloc('s profiler)
UNWIND_DIR=$(find_dir_of_lib unwind)
if [ ! -z "$UNWIND_DIR" ]; then
    if absent_in_the_list "$UNWIND_DIR" "$LIBS2"; then
        CONTENT="${CONTENT}\n    LIBS+=$UNWIND_DIR"
        LIBS2="${LIBS2}\n$UNWIND_DIR"
    fi
    if [ -f $UNWIND_DIR/libunwind.a ]; then
        CONTENT="${CONTENT}\n    STATIC_LINKING+=-lunwind"
    else
        CONTENT="${CONTENT}\n    DYNAMIC_LINKING+=-lunwind"
    fi
    # required by libunwind
    CONTENT="${CONTENT}\n    DYNAMIC_LINKING+=-llzma"
fi
CONTENT="${CONTENT}\nendif"
$ECHO "$CONTENT" > config.mk
