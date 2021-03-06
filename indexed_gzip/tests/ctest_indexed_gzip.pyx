#
# Tests for the indexed_gzip module.
#
# Author: Paul McCarthy <pauldmccarthy@gmail.com>
#

from __future__ import print_function

import               os
import os.path    as op
import itertools  as it
import subprocess as sp
import               sys
import               time
import               gzip
import               random
import               struct
import               hashlib
import               textwrap

import numpy as np

import pytest

import indexed_gzip as igzip

from . import gen_test_data
from . import check_data_valid
from . import testdir


def read_element(gzf, element, seek=True):

    if seek:
        gzf.seek(element * 8)

    bytes = gzf.read(8)
    val   = np.ndarray(1, np.uint64, buffer=bytes)

    return val[0]


def write_text_to_gzip_file(fname, lines):
    with gzip.open(fname, mode='wb') as f:
        for line in lines:
            f.write('{}\n'.format(line).encode())


def test_open_close(testfile, nelems, seed):

    f = igzip.IndexedGzipFile(filename=testfile)

    try:
        element = np.random.randint(0, nelems, 1)
        readval = read_element(f, element)

        assert readval == element

    finally:
        f.close()

    assert f.closed


def test_open_close_ctxmanager(testfile, nelems, seed):

    with igzip.IndexedGzipFile(filename=testfile) as f:

        element = np.random.randint(0, nelems, 1)
        readval = read_element(f, element)

    assert readval == element
    assert f.closed


def test_atts(testfile):

    modes = [None, 'rb', 'r']

    for m in modes:
        with igzip.IndexedGzipFile(filename=testfile, mode=m) as f:
            assert not f.closed
            assert     f.readable()
            assert     f.seekable()
            assert not f.writable()
            assert f.mode     == 'rb'
            assert f.tell()   == 0
            assert f.fileno() == f.fileobj().fileno()


def test_init_failure_cases(concat):

    with testdir() as td:
        testfile = op.join(td, 'test.gz')
        gen_test_data(testfile, 65536, concat)

        # No writing
        with pytest.raises(ValueError):
            gf = igzip.IndexedGzipFile(filename=testfile, mode='w')
        with pytest.raises(ValueError):
            gf = igzip.IndexedGzipFile(filename=testfile, mode='wb')

        # No writing
        f  = open(testfile, mode='wb')
        with pytest.raises(ValueError):
            gf = igzip.IndexedGzipFile(fid=f)
        f.close()

        # No writing
        f  = open(testfile, mode='w')
        with pytest.raises(ValueError):
            gf = igzip.IndexedGzipFile(fid=f)
        f.close()

        # Need a filename or fid
        with pytest.raises(ValueError):
            f = igzip.IndexedGzipFile()


def test_init_success_cases(concat):
    with testdir() as td:
        testfile = op.join(td, 'test.gz')
        gen_test_data(testfile, 65536, concat)

        gf1 = igzip.IndexedGzipFile(filename=testfile)
        gf2 = igzip.IndexedGzipFile(filename=testfile, mode='r')
        gf3 = igzip.IndexedGzipFile(filename=testfile, mode='rb')
        gf1.close()
        gf2.close()
        gf3.close()

def test_create_from_open_handle(testfile, nelems, seed):

    f   = open(testfile, 'rb')
    gzf = igzip.IndexedGzipFile(fid=f)

    element = np.random.randint(0, nelems, 1)
    readval = read_element(gzf, element)

    gzf.close()

    try:

        assert readval == element
        assert gzf.closed
        assert not f.closed

    finally:
        f.close()


def test_read_all(testfile, nelems, use_mmap):

    if use_mmap:
        pytest.skip('skipping test_read_all test as '
                    'it will require too much memory')

    with igzip.IndexedGzipFile(filename=testfile) as f:
        data = f.read(nelems * 8)

    data = np.ndarray(shape=nelems, dtype=np.uint64, buffer=data)

    # Check that every value is valid
    assert check_data_valid(data, 0)


def test_read_beyond_end(concat):
    with testdir() as tdir:
        nelems   = 65536
        testfile = op.join(tdir, 'test.gz')

        gen_test_data(testfile, nelems, concat)

        with igzip.IndexedGzipFile(filename=testfile, readall_buf_size=1024) as f:
            # Try with a specific number of bytes
            data1 = f.read(nelems * 8 + 10)

            # And also with unspecified numbytes
            f.seek(0)
            data2 = f.read()

        data1 = np.ndarray(shape=nelems, dtype=np.uint64, buffer=data1)
        data2 = np.ndarray(shape=nelems, dtype=np.uint64, buffer=data2)
        assert check_data_valid(data1, 0)
        assert check_data_valid(data2, 0)


def test_seek_and_read(testfile, nelems, niters, seed):

    with igzip.IndexedGzipFile(filename=testfile) as f:

        # Pick some random elements and make
        # sure their values are all right
        seekelems = np.random.randint(0, nelems, niters)

        for i, testval in enumerate(seekelems):

            readval = read_element(f, testval)

            ft = f.tell()

            assert ft      == (testval + 1) * 8
            assert readval == testval


def test_seek_and_tell(testfile, nelems, niters, seed):

    filesize = nelems * 8

    with igzip.IndexedGzipFile(filename=testfile) as f:

        # Pick some random seek positions
        # and make sure that seek and tell
        # return their location correctly
        seeklocs = np.random.randint(0, filesize, niters)

        for seekloc in seeklocs:

            st = f.seek(seekloc)
            ft = f.tell()

            assert ft == seekloc
            assert st == seekloc

        # Also test that seeking beyond
        # EOF is clamped to EOF
        eofseeks = [filesize,
                    filesize + 1,
                    filesize + 2,
                    filesize + 3,
                    filesize + 4,
                    filesize + 1000,
                    filesize * 1000]

        for es in eofseeks:
            assert f.seek(es) == filesize
            assert f.tell()   == filesize


def test_readinto():
    lines = textwrap.dedent("""
    line 1
    line 2
    this is line 3
    line the fourth
    here is the fifth line
    """).strip().split('\n')


    def line_offset(idx):
        return sum([len(l) for l in lines[:idx]]) + idx


    with testdir() as td:
        testfile = op.join(td, 'test.gz')
        write_text_to_gzip_file(testfile, lines)
        with igzip.IndexedGzipFile(filename=testfile) as f:

            # read first line into a byte array
            buf = bytearray(len(lines[0]))
            f.seek(0)
            assert f.readinto(buf) == len(lines[0])
            assert buf.decode() == lines[0]

            # read first line into memoryvew
            buf = memoryview(bytearray(len(lines[0])))
            f.seek(0)
            assert f.readinto(buf) == len(lines[0])
            assert buf.tobytes().decode() == lines[0]

            # read an arbitrary line
            offset = line_offset(2)
            buf = bytearray(len(lines[2]))
            f.seek(offset)
            assert f.readinto(buf) == len(lines[2])
            assert buf.decode() == lines[2]

            # read the end line, sans-newline
            offset = line_offset(len(lines) - 1)
            buf = bytearray(len(lines[-1]))
            f.seek(offset)
            assert f.readinto(buf) == len(lines[-1])
            assert buf.decode() == lines[-1]

            # read the end line, with newline
            buf = bytearray(len(lines[-1]) + 1)
            f.seek(offset)
            assert f.readinto(buf) == len(lines[-1]) + 1
            assert buf.decode() == lines[-1] + '\n'

            # read the end line with a bigger buffer
            buf = bytearray(len(lines[-1]) + 10)
            f.seek(offset)
            assert f.readinto(buf) == len(lines[-1]) + 1
            assert buf.decode() == lines[-1] + '\n' + (b'\0' * 9).decode()

            # start at EOF, and try to read something
            filelen = sum([len(l) for l in lines]) + len(lines)
            f.seek(filelen)
            buf = bytearray([99 for i in range(len(buf))])
            assert f.readinto(buf) == 0
            assert all([b == chr(99) for b in buf.decode()])


def test_readline():
    lines = textwrap.dedent("""
    this is
    some text
    split across
    several lines
    how creative
    """).strip().split('\n')

    with testdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip.IndexedGzipFile(fname) as f:
            seekpos = 0
            for line in lines:

                assert f.readline() == (line + '\n').encode()
                seekpos += len(line) + 1
                assert f.tell() == seekpos

            # Should return empty string after EOF
            assert f.readline() == b''


def test_readline_sizelimit():

    lines = ['line one', 'line two']

    with testdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip.IndexedGzipFile(fname) as f:

            # limit to one character before the end of the first line
            l = f.readline(len(lines[0]) - 1)
            assert l == (lines[0][:-1]).encode()

            # limit to the last character of the first line
            f.seek(0)
            l = f.readline(len(lines[0]) - 1)
            assert l == (lines[0][:-1]).encode()

            # limit to the newline at the end of the first line
            f.seek(0)
            l = f.readline(len(lines[0]) + 1)
            assert l == (lines[0] + '\n').encode()

            # limit to the first character after the first line
            f.seek(0)
            l = f.readline(len(lines[0]) + 2)
            assert l == (lines[0] + '\n').encode()


def test_readlines():
    lines = textwrap.dedent("""
    this is
    some more text
    split across
    several lines
    super imaginative
    test data
    """).strip().split('\n')

    with testdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip.IndexedGzipFile(fname) as f:

            gotlines = f.readlines()

            assert len(lines) == len(gotlines)

            for expl, gotl in zip(lines, gotlines):
                assert (expl + '\n').encode() == gotl

            assert f.read() == b''


def test_readlines_sizelimit():

    lines = ['line one', 'line two']
    data  = '\n'.join(lines) + '\n'

    with testdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        limits = range(len(data) + 2)

        with igzip.IndexedGzipFile(fname) as f:

            for lim in limits:
                f.seek(0)
                gotlines = f.readlines(lim)

                # Expect the first line
                if lim < len(lines[0]) + 1:
                    assert len(gotlines) == 1
                    assert gotlines[0] == (lines[0]  + '\n').encode()

                # Expect both lines
                else:
                    assert len(gotlines) == 2
                    assert gotlines[0] == (lines[0]  + '\n').encode()
                    assert gotlines[1] == (lines[1]  + '\n').encode()


def test_iter():

    lines = textwrap.dedent("""
    this is
    even more text
    that is split
    across several lines
    the creativity
    involved in generating
    this test data is
    unparalleled
    """).strip().split('\n')

    with testdir() as td:
        fname = op.join(td, 'test.gz')
        write_text_to_gzip_file(fname, lines)

        with igzip.IndexedGzipFile(fname) as f:
            for i, gotline in enumerate(f):
                assert (lines[i] + '\n').encode() == gotline

            with pytest.raises(StopIteration):
                 next(f)
