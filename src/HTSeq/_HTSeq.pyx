import sys
import os
import math
import re
import csv
import gzip
import itertools
import collections
try:
    import cStringIO
except:
    pass
import warnings
import numpy
cimport numpy

from HTSeq import StepVector
from HTSeq.StretchVector import StretchVector
from HTSeq import _HTSeq_internal


###########################
# GenomicInterval
###########################

cdef str strand_plus = intern("+")
cdef str strand_minus = intern("-")
cdef str strand_nostrand = intern(".")


cdef class GenomicInterval:
    """A range of consecutive positions on a reference genome.

        Properties:

        chrom: The name of a sequence (i.e., chromosome, contig, etc.).
        start: The start of the interval. Even on the reverse strand,
          this is always the smaller of the two values 'start' and 'end'.
          Note that all positions should be given as 0-based value!
        end: The end of the interval. Following Python convention for
          ranges, this in one more than the coordinate of the last base
          that is considered part of the sequence.
        strand: The strand, as a single character, '+' or '-'. '.' indicates
          that the strand is irrelavant. (Alternatively, pass a Strand object.)
        length: The length of the interval, i.e., end - start
        start_d: The "directional start" position. This is the position of the
          first base of the interval, taking the strand into account. Hence,
          this is the same as 'start' except when strand == '-', in which
          case it is end-1.
        end_d: The "directional end": Usually, the same as 'end', but for
          strand=='-1', it is start-1.
    """

    def __init__(GenomicInterval self, str chrom, long start, long end,
                 str strand=strand_nostrand):
        """See the class docstring for the meaning of the slots. Note that
        there is also a factory function, 'from_directional', to be used if
        you wish to specify start_d and length.
        """
        self.chrom = intern(chrom)
        self.start = start
        self.end = end
        self.strand = strand
        if self.start > self.end:
            raise ValueError("start is larger than end")

    property strand:
        def __set__(self, strand):
            strand = intern(strand)
            if not(strand is strand_plus or strand is strand_minus or
                    strand is strand_nostrand):
                raise ValueError("Strand must be'+', '-', or '.'.")
            self._strand = strand

        def __get__(self):
            return self._strand

    def __reduce__(GenomicInterval self):
        return GenomicInterval, (self.chrom, self.start, self.end,
                                 self.strand)

    def __copy__(self):
        constr, args = self.__reduce__()
        return constr(*args)

    def __repr__(GenomicInterval self):
        return "<%s object '%s', [%d,%s), strand '%s'>" % \
            (self.__class__.__name__, self.chrom, self.start,
             str(self.end) if self.end != sys.maxsize else "Inf", self.strand)

    def __str__(GenomicInterval self):
        return "%s:[%d,%s)/%s" % \
            (self.chrom, self.start, str(self.end)
             if self.end != sys.maxsize else "Inf", self.strand)

    property length:

        """The length is calculated as end - start. If you set the length,
        'start_d' will be preserved, i.e., 'end' is changed, unless the strand
        is '-', in which case 'start' is changed."""

        def __get__(GenomicInterval self):
            return self.end - self.start

        def __set__(GenomicInterval self, long newLength):
            if self._strand is not strand_minus:
                self.end = self.start + newLength
            else:
                self.start = self.end - newLength

    property start_d:
        """See the class docstring for the meaning of the 'directional start'.
        Note that if you set 'start_d', both the start and the end are changed,
        such the interval gets the requested new directional start and its
        length stays unchanged."""

        def __get__(GenomicInterval self):
            if self._strand is not strand_minus:
                return self.start
            else:
                return self.end - 1

        def __set__(GenomicInterval self, long newStartd):
            if self._strand is not strand_minus:
                self.end = newStartd + self.length
                self.start = newStartd
            else:
                self.start = newStartd + 1 - self.length
                self.end = newStartd + 1

    property end_d:

        def __get__(GenomicInterval self):
            if self._strand is not strand_minus:
                return self.end
            else:
                return self.start - 1

    property start_as_pos:
        def __get__(GenomicInterval self):
            return GenomicPosition(self.chrom, self.start, self. strand)

    property end_as_pos:
        def __get__(GenomicInterval self):
            return GenomicPosition(self.chrom, self.end, self. strand)

    property start_d_as_pos:
        def __get__(GenomicInterval self):
            return GenomicPosition(self.chrom, self.start_d, self. strand)

    property end_d_as_pos:
        def __get__(GenomicInterval self):
            return GenomicPosition(self.chrom, self.end_d, self. strand)

    def __richcmp__(GenomicInterval self, GenomicInterval other, int op):
        if op == 2:  # ==
            if other == None:
                return False
            return self._strand is other._strand and \
                self.start == other.start and self.end == other.end
        elif op == 3:  # !=
            return not (self == other)
        else:
            raise NotImplementedError

    def __hash__(GenomicInterval self):
        return hash((self.chrom, self.start, self.end, self.strand))

    cpdef is_contained_in(GenomicInterval self, GenomicInterval iv):
        """Returns a boolean value indicating whether the 'self' interval
        is fully within the 'iv' interval.

        This is deemed the case if
          - both are on the same chromosome, and
          - both are on the same strand, or at least one of them is
             not stranded (i.e., has strand == '.'), and
          - self.start >= iv.start, and
          - self.end <= iv.end
        """
        if iv == None:
            return False
        if self.chrom != iv.chrom:
            return False
        if self._strand is not strand_nostrand and iv.strand is not strand_nostrand and \
                self.strand is not iv._strand:
            return False
        if self.start < iv.start or self.end > iv.end:
            return False
        return True

    cpdef contains(GenomicInterval self, GenomicInterval iv):
        """Returns a boolean value indicating whether the 'self' interval
        fully contains the 'iv' interval.

        See 'is_contained_in' for the exact criteria.
        """
        if iv == None:
            return False
        return iv.is_contained_in(self)

    cpdef overlaps(GenomicInterval self, GenomicInterval iv):
        """Returns a boolean value indicating whether the 'self' interval
        overlaps the 'iv' interval.

        This is deemed the case if
          - both are on the same chromosome, and
          - both are on the same strand, or at least one of them is
             not stranded (i.e., has strand == '.'), and
          - the actual intervals overlap
        """
        if iv == None:
            return False
        if self.chrom != iv.chrom:
            return False
        if self.strand is not strand_nostrand and iv.strand is not strand_nostrand and \
                self.strand is not iv.strand:
            return False
        if self.start <= iv.start:
            return self.end > iv.start
        else:
            return iv.end > self.start

    def range(GenomicInterval self, long int step=1):
        """Generate an iterator over the GenomicPositions covered by the interval,
        running from start to end.
        """
        return _HTSeq_internal.GenomicInterval_range(self, step)

    def range_d(GenomicInterval self, long int step=1):
        """Generate an iterator over the GenomicPositions covered by the interval.
        running from start_d to end_d.
        """
        return _HTSeq_internal.GenomicInterval_ranged(self, step)

    cpdef extend_to_include(GenomicInterval self, GenomicInterval iv):
        """Extend the interval such that it includes iv."""
        if iv is None:
            raise TypeError("Cannot extend an interval to include None.")
        if self.chrom != iv.chrom:
            raise ValueError("Cannot extend an interval to include an interval on another chromosome.")
        if self.strand is not strand_nostrand and iv.strand is not strand_nostrand and \
                self.strand is not iv.strand:
            raise ValueError("Cannot extend an interval to include an interval on another strand.")
        self.start = min(self.start, iv.start)
        self.end = max(self.end, iv.end)

    def copy(self):
        return GenomicInterval(self.chrom, self.start, self.end, self.strand)


def GenomicInterval_from_directional(str chrom, long int start_d, long int length, str strand="."):
    strand = intern(strand)
    if strand.se is not strand_minus:
        return GenomicInterval(chrom, start_d, start_d + length, strand)
    else:
        return GenomicInterval(chrom, start_d - length + 1, start_d + 1, strand)


cdef class GenomicPosition(GenomicInterval):
    """Position of a nucleotide or base pair on a reference genome.

    Properties:
       chrom: The name of a sequence (i.e., chromosome, contig, etc.).
       pos: The position on the sequence specified by seqname.
          The position should always be given as 0-based value!
       strand: The strand, as a single character, '+' or '-'. '.' indicates
          that the strand is irrelavant.

    The GenomicPosition class is derived from GenomicInterval. Hence,
    a GenomicPosition is always a GenomicInterval of length 1. Do not tinker
    with the exposed GenomeInterval properties.
    """

    def __init__(self, str chrom, long int pos, str strand='.'):
        GenomicInterval.__init__(self, chrom, pos, pos + 1, strand)

    property pos:
        """Alias for 'start_d'."""

        def __get__(self):
            return self.start_d

        def __set__(self, long newValue):
            self.start_d = newValue

    property end:

        def __get__(self):
            return self.start + 1

    property length:

        def __get__(self):
            return 1

    def __repr__(self):
        return "<%s object '%s':%d, strand '%s'>" % \
            (self.__class__.__name__, self.chrom, self.pos, self.strand)

    def __str__(self):
        return "%s:%d/%s" % (self.chrom, self.pos, self.strand)

    def __reduce__(GenomicPosition self):
        return GenomicPosition, (self.chrom, self.pos, self.strand)

    def copy(self):
        return GenomicPosition(self.chrom, self.pos, self.strand)


cdef class ChromVector(object):
    """Counting vector covering a chromosome.

    This class supports three types of storage:
      1. 'ndarray': Use a dense 1D numpy array
      2. 'memmap': Use numpy memory maps on disk for large arrays
      3. 'step': Use a StepVector
    """

    cdef public object array
    cdef public GenomicInterval iv
    cdef public int offset
    cdef public bint is_vector_of_sets
    cdef public str _storage
    cdef public str typecode
    cdef public str memmap_dir

    @classmethod
    def create(cls, GenomicInterval iv, str typecode, str storage, str memmap_dir=""):
        """Create ChromVector from GenomicInterval

        Args:
            iv (GenomicInterval): A GenomicInterval describing the chromosome
              vector.
            typecode ('d', 'i', 'l', 'b', or 'O'): What kind of data will be
              stored inside this chromosome vector. 'd' for double, 'i' for int,
              'l' for long int, 'b' for boolean, 'O' for arbitrary objects
              (e.g. sets).
            storage ('step', 'ndarray', or 'memmap'): What kind of storage to
              use. 'ndarray' is appropriate for short chromosomes and stores
              each position in the genome into memory. 'memmap' stores all
              positions, but maps the memory onto disk for larger chromosomes.
              'step' is a sparse representation similar to CSR matrices whereby
              only the boundaries between genomic stretches with differing
              data content are stored - see HTSeq.StepVector.
            memmap_dir (str): If using 'memmap' storage, what folder to store
              the memory maps. These can get quite big.

        Returns:
            An instance of ChromVector with the requested options.

        """
        ncv = cls()
        ncv.iv = iv

        if storage == "ndarray":
            if typecode != 'O':
                ncv.array = numpy.zeros(shape=(iv.length,), dtype=typecode)
            else:
                ncv.array = numpy.empty(shape=(iv.length,), dtype=typecode)
                ncv.array[:] = None

        elif storage == "memmap":
            ncv.array = numpy.memmap(
                shape=(iv.length,),
                dtype=typecode,
                filename=os.path.join(
                    memmap_dir,
                    iv.chrom + iv.strand + str(iv.start) + '_' \
                        + str(iv.length) + ".nmm"),
                mode='w+')

        elif storage == "step":
            ncv.array = StepVector.StepVector.create(
                typecode=typecode,
            )
        elif storage == "stretch":
            ncv.array = StretchVector(
                    typecode=typecode,
            )

        else:
            raise ValueError("Illegal storage mode.")

        ncv._storage = storage
        ncv.typecode = typecode
        # NOTE: As long as autochromosomes in GenomicArray are infinite length
        # this has pretty limited use, but that might change
        ncv.offset = iv.start
        ncv.is_vector_of_sets = False
        ncv.memmap_dir = memmap_dir
        return ncv

    @classmethod
    def _create_view(cls, ChromVector vec, GenomicInterval iv):
        if iv.length == 0:
            raise IndexError("Cannot subset to zero-length interval.")
        v = cls()
        v.iv = iv
        v.array = vec.array
        v.offset = vec.offset
        v.is_vector_of_sets = vec.is_vector_of_sets
        v._storage = vec._storage
        return v

    def extend_to_include(self, iv):
        if iv.strand != self.iv.strand:
            raise ValueError(
                'The new interval must match the current strandedness',
            )

        # Step 1: extend the interval
        length = self.iv.length
        startdiff = max(self.iv.start - iv.start, 0)
        self.iv.extend_to_include(iv)
        self.offset = self.iv.start

        # Step 2: extend the array if needed, and shift-copy the old values
        if self._storage == 'ndarray':
            if self.typecode != 'O':
                array = numpy.zeros(shape=(self.iv.length,), dtype=self.typecode)
            else:
                array = numpy.empty(shape=(self.iv.length,), dtype=self.typecode)
                array[:] = None
            array[startdiff: startdiff + length] = self.array[:]
        elif self._storage == 'memmap':
            array = numpy.memmap(
                shape=(self.iv.length,), dtype=self.typecode,
                filename=os.path.join(
                    self.memmap_dir,
                    self.iv.chrom + self.iv.strand + str(self.iv.start) + '_' \
                        + str(self.iv.length) + ".nmm"),
                mode='w+',
            )
            array[startdiff: startdiff + length] = self.array[:]
        else:
            # The StepVector is created in ChromVector.create without explicit
            # boundaries, so it's already bound by 0, +inf. So we do not need
            # to extend it here, but rather just set the slice to the right
            # value
            array = self.array
        self.array = array

    def __getitem__(self, index):
        """Index or slice the chromosome.

        The index can be a few things:
        - an integer: get the value of the vector at that chromosome coordinate
        - a 1-step slice e.g "4:7": get a view of the chromosome region
          between those coordinates. The array data are not copied.
        - a GenomicInterval: similar to slices, with the additional choice of
          strandedness. If this argument is stranded but the chromosome itself
          is not stranded, a nonstranded view of the chromosome region is
          returned.

        """
        cdef slice index_slice
        cdef long int index_int
        cdef long int start, stop
        cdef GenomicInterval iv

        if isinstance(index, int):
            index_int = index
            if index_int < self.iv.start or index_int >= self.iv.end:
                raise IndexError
            return self.array[index_int - self.offset]

        elif isinstance(index, slice):
            index_slice = index
            if index_slice.start is None:
                start = self.iv.start
            else:
                start = index_slice.start
                if start < self.iv.start:
                    raise IndexError("start too small")

            if index_slice.stop is None:
                stop = self.iv.end
            else:
                stop = index_slice.stop
                if stop > self.iv.end:
                    raise IndexError("stop too large")

            iv = GenomicInterval(self.iv.chrom, start, stop, self.iv.strand)

            if not self.iv.contains(iv):
                raise IndexError
            return ChromVector._create_view(self, iv)

        elif isinstance(index, GenomicInterval):
            if not self.iv.contains(index):
                raise IndexError

            if self.iv.strand is strand_nostrand and \
                    index.strand is not strand_nostrand:
                iv = index.copy()   # Is this correct now?
                iv.strand = strand_nostrand
            else:
                iv = index

            return ChromVector._create_view(self, iv)

        else:
            raise TypeError("Illegal index type")

    def __setitem__(self, index, value):
        cdef slice index_slice
        cdef long int start, stop

        if isinstance(value, ChromVector):
            if self.array is value.array and value.iv.start == index.start and \
                    value.iv.end == index.stop and (index.step is None or index.step == 1):
                return
            else:
                raise NotImplementedError(
                    "Required assignment signature not yet implemented.")

        if isinstance(index, int):
            self.array[index - self.iv.start] = value

        elif isinstance(index, slice):
            index_slice = index
            if index_slice.start is not None:
                start = index_slice.start
                if start < self.iv.start:
                    raise IndexError("start too small")
            else:
                start = self.iv.start
            if index_slice.stop is not None:
                stop = index_slice.stop
                if stop > self.iv.end:
                    raise IndexError("stop too large")
            else:
                stop = self.iv.end
            if start > stop:
                raise IndexError("Start of interval is after its end.")
            if start == stop:
                raise IndexError("Cannot assign to zero-length interval.")
            self.array[start - self.offset: stop -
                       self.iv.start: index.step] = value

        elif isinstance(index, GenomicInterval):
            if index.chrom != self.iv.chrom:
                raise KeyError("Chromosome name mismatch.")
            if self.iv.strand is not strand_nostrand and \
                    self.iv.strand is not self.index.strand:
                raise KeyError("Strand mismatch.")
            self.array[index.iv.start - self.iv.start,
                       index.iv.end - self.iv.start] = value
        else:
            raise TypeError("Illegal index type")

    def __iadd__(self, value):
        if not self.is_vector_of_sets:
            self.array[self.iv.start - self.offset: self.iv.end -
                       self.offset].__iadd__(value)
        else:
            def addval(x):
                y = x.copy()
                y.add(value)
                return y

            self.apply(addval)
        return self

    def __iter__(self):
        return self.values()

    def values(self):
        return iter(self.array[self.iv.start - self.offset: self.iv.end - self.offset])

    def steps(self):
        return _HTSeq_internal.ChromVector_steps(self)

    def apply(self, fun):
        for iv, value in self.steps():
            self.array[iv.start - self.offset: iv.end -
                       self.offset] = fun(value)

    def __repr__(self):
        return "<%s object, %s, %s>" % (self.__class__.__name__, str(self.iv), self._storage)

    def __reduce__(self):
        assert self.__class__ is ChromVector
        return(_ChromVector_unpickle,
               (self.array, self.iv, self.offset, self.is_vector_of_sets, self._storage))


def _ChromVector_unpickle(array, iv, offset, is_vector_of_sets, _storage):
    cv = ChromVector()
    cv.array = array
    cv.iv = iv
    cv.offset = offset
    cv.is_vector_of_sets = is_vector_of_sets
    cv._storage = _storage
    return cv


cdef class GenomicArray(object):
    """Coverage vector including multiple chromosomes.

    This object is basically a collection of ChromVector, with the same options
    for storage:
      1. 'ndarray': Use a dense 1D numpy array
      2. 'memmap': Use numpy memory maps on disk for large arrays
      3. 'step': Use a StepVector

    The class also supports autodiscovery of chromosomes if the 'step' storage
    method is used. In that case, chromosomes of at least sufficient size will
    be created whenever the data pushed into the GenomicArray refers to them.
    For instance, if you are computing plain read coverage along chromosomes,
    each read will inform the GenomicArray as of its chromosome and position:
    the GenomicArray will then create an appropriate ChromVector object of at
    least that size.
    """

    cdef public dict chrom_vectors
    cdef readonly bint stranded
    cdef readonly str typecode
    cdef public str auto_add_chroms
    cdef readonly str storage
    cdef readonly str memmap_dir
    cdef public str header

    def __init__(self, object chroms, bint stranded=True, str typecode='d',
                 str storage='step', str memmap_dir="", str header=""):
        '''GenomicArray(chroms, stranded=True, typecode="d", storage="step", memmap_dir="")

        Initialize GenomicArray

        Args:
            chroms (str, list, or dict): Chromosomes in the GenomicArray. If
              'auto', make infinitely long chromosomes upon the first get or
              set. If 'auto-write', never make new chromosomes upon a get but
              make large enough chromosomes upon the first set.
              If a list, make infinitely long chromosomes with those names.
              If a dict, keys are chromosome names and
              values are their lengths in base pairs. The first two options are
              only available for the 'step' storage (see below).
            stranded (bool): whether the array stores strandedness information.
            typecode ('d', 'i', 'l', 'b', 'O'): what kind of data the array
              will contain. 'd' for double, 'i' for int, 'l' for long int, 'b'
              for boolean, 'O' for arbitrary objects (e.g. sets).
            storage ('step', 'stretch', 'ndarray', or 'memmap'): What kind of
              storage to use. 'ndarray' is appropriate for short chromosomes
              and stores each position in the genome into memory. 'memmap'
              stores all positions, but maps the memory onto disk for larger
              chromosomes. 'step' is a sparse representation similar to CSR
              matrices whereby only the boundaries between genomic stretches
              with differing data content are stored - see HTSeq.StepVector.
              'stretch' is a sparse representation with rare, dense 'islands'
              of data in a sea of missing data along chromosomes.
            memmap_dir (str): If using 'memmap' storage, what folder to store
              the memory maps. These can get quite big.
            header (str): A header with metadata (e.g. when parsing a BedGraph
              file, having the header helps writing it out with all browser
              options retained).

        Returns:
            An instance of GenomicArray with the requested options.
        '''


        self.auto_add_chroms = chroms if chroms in ('auto', 'auto-write') else ''
        self.chrom_vectors = {}
        self.stranded = stranded
        self.typecode = typecode
        self.header = header

        if self.auto_add_chroms:
            chroms = []
            if storage not in ('step', 'stretch'):
                raise TypeError("Automatic adding of chromosomes can " + \
                    " only be used with storage type 'step' or 'stretch'.")

        elif isinstance(chroms, list):
            if storage not in ('step', 'stretch'):
                raise TypeError("Indefinite-length chromosomes can " + \
                    " only be used with storage type 'step' or 'stretch'.")
            chroms = dict([(c, sys.maxsize) for c in chroms])

        elif not isinstance(chroms, dict):
            raise TypeError("'chroms' must be a list or a dict or 'auto'.")

        self.storage = storage
        self.memmap_dir = memmap_dir

        for chrom in chroms:
            self.add_chrom(chrom, chroms[chrom])

    def __getitem__(self, index):
        if isinstance(index, GenomicInterval):
            if self.stranded and index.strand not in (strand_plus, strand_minus):
                raise KeyError(
                    "Non-stranded index used for stranded GenomicArray.")

            # Auto-add chromosome: always infinite size
            if (self.auto_add_chroms == 'auto') and index.chrom not in self.chrom_vectors:
                self.add_chrom(index.chrom)

            if isinstance(index, GenomicPosition):
                if self.stranded:
                    return self.chrom_vectors[index.chrom][index.strand][index.pos]
                else:
                    return self.chrom_vectors[index.chrom][strand_nostrand][index.pos]
            else:
                if self.stranded:
                    return self.chrom_vectors[index.chrom][index.strand][index.start: index.end]
                else:
                    return self.chrom_vectors[index.chrom][strand_nostrand][index.start: index.end]
        else:
            return self.chrom_vectors[index]

    def __setitem__(self, index, value):
        cdef GenomicInterval index2

        if isinstance(value, ChromVector):
            if not isinstance(index, GenomicInterval):
                raise NotImplementedError(
                    "Required assignment signature not yet implemented.")
            index2 = index.copy()
            if not self.stranded:
                index2.strand = strand_nostrand
            if self.chrom_vectors[index2.chrom][index2.strand].array is value.array and index2 == value.iv:
                return
            raise NotImplementedError(
                    "Required assignment signature not yet implemented.")

        if isinstance(index, GenomicInterval):
            if self.stranded and index.strand not in (strand_plus, strand_minus):
                raise KeyError(
                    "Non-stranded index used for stranded GenomicArray.")

            # Auto-add chromosome: always infinite size
            # Before changing this, make sure __setitem__ and __getitem__ are
            # consistent
            if self.auto_add_chroms in ('auto', 'auto-write'):
                # Add a new chromosome
                if index.chrom not in self.chrom_vectors:
                    if self.auto_add_chroms == 'auto':
                        self.add_chrom(index.chrom)
                    else:
                        self.add_chrom(
                                index.chrom,
                                length=index.end - index.start,
                                start_index=index.start,
                        )
                # Extend a known chromosome
                else:
                    if self.stranded:
                        self.chrom_vectors[index.chrom][index.strand].extend_to_include(
                            index,
                        )
                    else:
                        self.chrom_vectors[index.chrom][strand_nostrand].extend_to_include(
                            index,
                        )

            if self.stranded:
                self.chrom_vectors[index.chrom][index.strand][
                    index.start: index.end] = value
            else:
                self.chrom_vectors[index.chrom][strand_nostrand][
                    index.start: index.end] = value
        else:
            raise TypeError("Illegal index type.")

    def add_chrom(self, chrom, length=sys.maxsize, start_index=0):
        cdef GenomicInterval iv
        if length == sys.maxsize:
            iv = GenomicInterval(chrom, start_index, sys.maxsize, ".")
        else:
            iv = GenomicInterval(chrom, start_index, start_index + length, ".")
        if self.stranded:
            self.chrom_vectors[chrom] = {}
            iv.strand = "+"
            self.chrom_vectors[chrom][strand_plus] = \
                ChromVector.create(iv, self.typecode,
                                   self.storage, self.memmap_dir)
            iv = iv.copy()
            iv.strand = "-"
            self.chrom_vectors[chrom][strand_minus] = \
                ChromVector.create(iv, self.typecode,
                                   self.storage, self.memmap_dir)
        else:
            self.chrom_vectors[chrom] = {
                strand_nostrand:  ChromVector.create(iv, self.typecode,
                                                     self.storage,
                                                     self.memmap_dir)}

    def __reduce__(self):
        return (_GenomicArray_unpickle, (self.stranded, self.typecode, self.chrom_vectors))

    def write_bedgraph_file(
            self,
            file_or_filename,
            strand=".",
            track_options="",
            separator='\t',
            ):
        '''Write GenomicArray to BedGraph file

        BedGraph files are used to visualize genomic "tracks", notably in
        UCSC's genomic viewer. This function stores the GenomicArray into such
        a file for further use.

        Args:
            file_or_filename (str, path, or open file handle): Where to store
              the BedGraph data.
            strand ("+", "-", or "."): Which strand to store the array onto.
            track_options (str): A string pre-formatted to describe the track
              options as they appear on the first line of the BedGraph file,
              after "track type=bedGraph".
            separator (str): the pattern that separates the columns.

        The BedGraph file format is described here:

            http://genome.ucsc.edu/goldenPath/help/bedgraph.html
        '''
        sep = separator

        if (not self.stranded) and strand != ".":
            raise ValueError("Strand specified in unstranded GenomicArray.")
        if self.stranded and strand not in (strand_plus, strand_minus):
            raise ValueError("Strand must be specified for stranded GenomicArray.")
        if hasattr(file_or_filename, "write"):
            f = file_or_filename
        else:
            f = open(file_or_filename, "w")

        try:
            if self.header:
                f.write(self.header)
                if not self.header.endswith('\n'):
                    f.write('\n')
            if track_options == "":
                f.write("track type=bedGraph\n")
            else:
                f.write("track type=bedGraph %s\n" % track_options)
            for chrom in self.chrom_vectors:
                for iv, value in self.chrom_vectors[chrom][strand].steps():
                    if iv.start == -sys.maxsize - 1 or iv.end == sys.maxsize:
                        continue
                    f.write(
                        sep.join(
                            (iv.chrom, str(iv.start), str(iv.end), str(value)),
                            )+'\n',
                        )
        finally:
            # Close the file only if we were the ones to open it
            if not hasattr(file_or_filename, "write"):
                f.close()

    @classmethod
    def from_bedgraph_file(cls, file_or_filename, strand=".", typecode="d"):
        '''Create GenomicArray from BedGraph file

        See GenomicArray.write_bedgraph_file for details on the file format.

        Args:
            file_or_filename (str, path, or open file handle): Where to load
              the BedGraph data from.
            strand ("+", "-", or "."): strandedness of the returned array.
            typecode ("d", "i", or "l"): Type of data in the file.
              "d" means floating point (double), "i" is integer, "l" is long
              integer.

        Returns:
            A GenomicArray instance with the data.
        '''
        if hasattr(file_or_filename, "read"):
            f = file_or_filename
        else:
            f = open(file_or_filename, "r")

        try:
            # Find beginning of actual contents
            header = []
            for line in f:
                if line.startswith('track type=bedGraph'):
                    break
                header.append(line)
            else:
                raise IOError(
                    "header line with 'track type=bedGraph' not found."
                )

            # Create the instance with autochromosomes
            array = cls(
                "auto-write",
                stranded=strand != ".",
                typecode=typecode,
                storage='step',
                header=''.join(header),
            )

            # Load contents
            for line in f:
                chrom, start, end, value = line.rstrip('\n\r').split()
                start, end = int(start), int(end)
                if typecode in ('i', 'l'):
                    value = int(value)
                elif typecode == 'd':
                    value = float(value)
                else:
                    raise ValueError(f"Typecode not supported: {typecode}")

                iv = GenomicInterval(chrom, start, end, strand=strand)
                array[iv] = value

        finally:
            # Close the file only if we were the ones to open it
            if not hasattr(file_or_filename, "read"):
                f.close()

        return array

    def write_bigwig_file(
            self,
            filename,
            strand='.',
            ):
        '''Write GenomicArray to BigWig file

        BigWig files are used to visualize genomic "tracks", notably in
        UCSC's genomic viewer. They are, in a sense, the binary compressed
        equivalent of BedGraph files. This function stores the GenomicArray
        into such a file for further use.

        Args:
            filename (str or path): Where to store the data.
            strand (".", "+", or "-"): Which strand to write to file.

        The BigWig file format is described here:

            http://genome.ucsc.edu/goldenPath/help/bigWig.html

        NOTE: This function requires the package pyBigWig at:

            https://github.com/deeptools/pyBigWig

        Install it via pip, conda, or see instructions at that page.
        '''
        try:
            import pyBigWig
        except ImportError:
            raise ImportError(
                'pyBigWig is required to write a GenomicArray to a bigWig file',
            )

        if (not self.stranded) and strand != ".":
            raise ValueError("Strand specified in unstranded GenomicArray.")
        if self.stranded and strand not in (strand_plus, strand_minus):
            raise ValueError("Strand must be specified for stranded GenomicArray.")

        with pyBigWig.open(filename, "w") as bw:
            # Write header with chromosome info
            header = []
            for chrom in self.chrom_vectors:
                cv = self.chrom_vectors[chrom][strand]
                end = cv.iv.end
                header.append((chrom, end))
            bw.addHeader(header)

            # Write data (use a buffer for efficiency)
            entries = {'chrom': [], 'start': [], 'ends': [], 'values': []}
            bufsize = 1000

            def write_with_buffer(bw, entries, bufsize, newentry=None):
                if newentry is not None:
                    for key in entries:
                        entries[key].append(newentry[key])
                if len(entries) >= bufsize:
                    bw.addEntries(
                        entries['chrom'], entries['start'],
                        ends=entries['ends'], values=entries['values'],
                    )
                    for key in entries:
                        entries[key].clear()

            for chrom in self.chrom_vectors:
                cv = self.chrom_vectors[chrom][strand]
                for iv, value in cv.steps():
                    if iv.start == -sys.maxsize - 1 or iv.end == sys.maxsize:
                        continue

                    entry = {
                        'chrom': chrom,
                        'start': iv.start,
                        'ends': iv.end,
                        'values': value,
                    }
                    write_with_buffer(bw, entries, bufsize, newentry=entry)
            # Flush buffer
            write_with_buffer(bw, entries, bufsize=1)

    @classmethod
    def from_bigwig_file(cls, filename, strand=".", typecode="d"):
        '''Create GenomicArray from BigWig file

        See GenomicArray.write_bigwig for details on the file format.

        Args:
            filename (str or path): Where to load the data from.
            strand ("+", "-", or "."): strandedness of the returned array.
            typecode ("d", "i", or "l"): Type of data in the file.
              "d" means floating point (double), "i" is integer, "l" is long
              integer.

        Returns:
            A GenomicArray instance with the data.
        '''
        try:
            import pyBigWig
        except ImportError:
            raise ImportError(
                'pyBigWig is required to write a GenomicArray to a bigWig file',
            )

        # Avoid circular import
        from HTSeq import BigWig_Reader

        with BigWig_Reader(filename) as bw:
            chrom_dict = dict(bw.chroms())

            # Create the instance with specified chromosomes
            array = cls(
                chrom_dict,
                stranded=strand != ".",
                typecode=typecode,
                storage='step',
            )

            for chrom in chrom_dict:
                intervals = bw.intervals(chrom, raw=True)
                for i, (start, end, value) in enumerate(intervals):
                    # Set the chromosome offset with the first value, since
                    # they are ordered. The StepVector will be offset compared
                    # to that.
                    if i == 0:
                        array.chrom_vectors[chrom][strand].offset = start
                        array.chrom_vectors[chrom][strand].iv.start = start

                    # Bypass GenomicArray.__setitem__ for efficiency
                    # This can be done because, unlike for BedGraph files,
                    # we know the length of chromosomes a priori from the
                    # header.
                    array.chrom_vectors[chrom][strand][start: end] = value

        return array

    def steps(self):
        '''Get the steps, independent of storage method

        Each "step" is a GenomicInterval with fixed value of the array. For
        instance, if we have 3 counts on chromosome '1' between 0 and 10
        (exclded) and 6 counts between 10 and 20 (end of chromosome), we would
        get two steps: (0, 10, 3) and (10, 20, 6). If the GenomicArray is
        stranded, genomic intervals of the appropriate strandedness are
        returned.
        '''
        return _HTSeq_internal.GenomicArray_steps(self)


def _GenomicArray_unpickle(stranded, typecode, chrom_vectors):
    ga = GenomicArray({}, stranded, typecode)
    ga.chrom_vectors = chrom_vectors
    return ga


###########################
# Sequences
###########################


def _make_translation_table_for_complementation():
    return bytes.maketrans(b'ACGTacgt', b'TGCAtgca')


cdef bytes _translation_table_for_complementation = _make_translation_table_for_complementation()


cpdef bytes reverse_complement(bytes seq):
    """Returns the reverse complement of DNA sequence 'seq'. Does not yet
    work with extended IUPAC nucleotide letters or RNA."""

    return seq[::-1].translate(_translation_table_for_complementation)


base_to_column = {'A': 0, 'C': 1, 'G': 2, 'T': 3, 'N': 4}


cdef class Sequence(object):
    """A Sequence, typically of DNA, with a name."""

    def __init__(self, bytes seq, str name="unnamed"):
        self.seq = seq
        self.name = name
        self.descr = None

    cpdef Sequence get_reverse_complement(self, bint rename=True):
        if rename:
            return Sequence(
                reverse_complement(self.seq),
                "revcomp_of_" + self.name)
        else:
            return Sequence(
                reverse_complement(self.seq),
                self.name)

    def __str__(self):
        return self.seq.decode()

    def __repr__(self):
        return "<%s object '%s' (length %d)>" % (
            self.__class__.__name__, self.name, len(self.seq))

    def __len__(self):
        return len(self.seq)

    def __getitem__(self, item):
        if self.name.endswith("[part]"):
            new_name = self.name
        else:
            new_name = self.name + "[part]"
        return Sequence(self.seq[item], new_name)

    def __getstate__(self):
        return {'seq': self.seq,
                'name': self.name,
                'descr': self.descr}

    def __setstate__(self, state):
        self.seq = state['seq']
        self.name = state['name']
        self.descr = state['descr']

    def __reduce__(self):
        return (self.__class__, (self.seq, self.name), self.__getstate__())

    def write_to_fasta_file(self, fasta_file, characters_per_line=70):
        """Write sequence to file in FASTA format.

        Arguments:
                - fasta_file (file handle): destination file
                    - characters_per_line (int >=0): if 0, write the whole sequence on a single line. Otherwise, break into several lines if the sequence is long enough.

        """
        if self.descr is not None:
            fasta_file.write(">%s %s\n" % (self.name, self.descr))
        else:
            fasta_file.write(">%s\n" % self.name)

        if characters_per_line == 0:
            fasta_file.write(self.seq.decode() + "\n")
        else:
            i = 0
            while i * characters_per_line < len(self.seq):
                fasta_file.write(
                    self.seq[i * characters_per_line: (i + 1) * characters_per_line].decode() + "\n")
                i += 1

    cpdef object add_bases_to_count_array(Sequence self, numpy.ndarray count_array_):

        cdef numpy.ndarray[numpy.int_t, ndim = 2] count_array = count_array_
        cdef int seq_length = len(self.seq)

        if numpy.PyArray_DIMS(count_array)[0] < seq_length:
            raise ValueError("'count_array' too small for sequence.")
        if numpy.PyArray_DIMS(count_array)[1] < 5:
            raise ValueError("'count_array' has too few columns.")

        cdef numpy.npy_intp i
        cdef char b
        cdef char * seq_cstr = self.seq
        for i in range(seq_length):
            b = seq_cstr[i]
            if b in [b'A', b'a']:
                count_array[i, 0] += 1
            elif b in [b'C', b'c']:
                count_array[i, 1] += 1
            elif b in [b'G', b'g']:
                count_array[i, 2] += 1
            elif b in [b'T', b't']:
                count_array[i, 3] += 1
            elif b in [b'N', b'n', b'.']:
                count_array[i, 4] += 1
            else:
                raise ValueError("Illegal base letter encountered.")

        return None

    cpdef Sequence trim_left_end(Sequence self, Sequence pattern, float mismatch_prop=0.):
        cdef int seqlen = len(self.seq)
        cdef int patlen = len(pattern.seq)
        cdef int minlen
        if seqlen < patlen:
            minlen = seqlen
        else:
            minlen = patlen
        cdef char * seq_cstr = self.seq
        cdef char * pat_cstr = pattern.seq
        cdef int match = 0
        cdef int i, j
        cdef int num_mismatches
        for i in range(1, minlen + 1):
            num_mismatches = 0
            for j in range(i):
                if seq_cstr[j] != pat_cstr[patlen - i + j]:
                    num_mismatches += 1
                    if num_mismatches > mismatch_prop * i:
                        break
            else:
                match = i
        return self[match: seqlen]

    cpdef Sequence trim_right_end(Sequence self, Sequence pattern, float mismatch_prop=0.):
        cdef int seqlen = len(self.seq)
        cdef int patlen = len(pattern.seq)
        cdef int minlen
        if seqlen < patlen:
            minlen = seqlen
        else:
            minlen = patlen
        cdef char * seq_cstr = self.seq
        cdef char * pat_cstr = pattern.seq
        cdef int match = 0
        cdef int i, j
        cdef int num_mismatches
        for i in range(1, minlen + 1):
            num_mismatches = 0
            for j in range(i):
                if seq_cstr[seqlen - i + j] != pat_cstr[j]:
                    num_mismatches += 1
                    if num_mismatches > mismatch_prop * i:
                        break
            else:
                match = i
        return self[0: seqlen - match]


cdef class SequenceWithQualities(Sequence):
    """A Sequence with base-call quality scores.
    It now has property  'qual', an integer NumPy array of Sanger/Phred
    quality scores of the  base calls.
    """

    def __init__(self, bytes seq, str name, bytes qualstr, str qualscale="phred"):
        """ Construct a SequenceWithQuality object.

          seq       - The actual sequence.
          name      - The sequence name or ID
          qualstr   - The quality string. Must have the same length as seq
          qualscale - The encoding scale of the quality string. Must be one of
                        "phred", "solexa", "solexa-old", or "noquals" )
        """
        Sequence.__init__(self, seq, name)
        if qualscale != "noquals":
            if len(seq) != len(qualstr):
                raise ValueError("'seq' and 'qualstr' do not have the same length.")
            self._qualstr = qualstr
        else:
            self._qualstr = b''
        self._qualscale = qualscale
        self._qualarr = None
        self._qualstr_phred = b''

    cdef _fill_qual_arr(SequenceWithQualities self):
        cdef int seq_len = len(self.seq)
        if self._qualscale == "missing":
            raise ValueError("Quality string missing.")
        if seq_len != len(self._qualstr):
            raise ValueError("Quality string has not the same length as sequence.")
        cdef numpy.ndarray[numpy.uint8_t, ndim= 1] qualarr = numpy.empty((seq_len, ), numpy.uint8)
        cdef int i
        cdef char * qualstr = self._qualstr
        if self._qualscale == "phred":
            for i in range(seq_len):
                qualarr[i] = qualstr[i] - 33
        elif self._qualscale == "solexa":
            for i in range(seq_len):
                qualarr[i] = qualstr[i] - 64
        elif self._qualscale == "solexa-old":
            for i in range(seq_len):
                qualarr[i] = 10 * \
                    math.log10(1 + 10 ** (qualstr[i] - 64) / 10.0)
        else:
            raise ValueError("Illegal quality scale '%s'." % self._qualscale)
        self._qualarr = qualarr

    property qual:
        def __get__(self):
            if self._qualarr is None:
                self._fill_qual_arr()
            return self._qualarr

        def __set__(self, newvalue):
            if not (isinstance(newvalue, numpy.ndarray) and newvalue.dtype == numpy.uint8):
                raise TypeError("qual can only be assigned a numpy array of type numpy.uint8")
            if not (newvalue.shape == (len(self.seq), )):
                raise TypeError("assignment to qual with illegal shape")
            self._qualarr = newvalue
            self._qualstr = b""
            self._qualscale = "none"
            self._qualstr_phred = b""
            # Experimentally trying to set qualstr when the array is modified
            # directly
            tmp = self.qualstr
            self._qualstr = self._qualstr_phred

    def __repr__(self):
        return "<%s object '%s'>" % (self.__class__.__name__, self.name)

    def __getitem__(self, item):
        if self.name.endswith("[part]"):
            new_name = self.name
        else:
            new_name = self.name + "[part]"
        return SequenceWithQualities(
            self.seq[item], new_name, self.qualstr[item])

    @property
    def qualstr(self):
        cdef int seqlen
        cdef char * qualstr_phred_cstr = self._qualstr_phred
        cdef int i
        cdef numpy.ndarray[numpy.uint8_t, ndim = 1] qual_array
        if qualstr_phred_cstr[0] == 0:
            if self._qualscale == "noquals":
                raise ValueError("Quality string missing")
            if self._qualscale == "phred":
                self._qualstr_phred = self._qualstr
            else:
                seqlen = len(self.seq)
                # FIXME: is this fixed now?
                self._qualstr_phred = b' ' * seqlen
                qualstr_phred_cstr = self._qualstr_phred
                if self._qualarr is None:
                    self._fill_qual_arr()
                qual_array = self._qualarr
                for i in range(seqlen):
                    qualstr_phred_cstr[i] = 33 + qual_array[i]
        return self._qualstr_phred

    def write_to_fastq_file(self, fastq_file):
        if hasattr(self, "descr") and self.descr is not None:
            fastq_file.write("@%s %s\n" % (self.name, self.descr))
        else:
            fastq_file.write("@%s\n" % self.name)
        fastq_file.write(self.seq.decode() + "\n")
        fastq_file.write("+\n")
        fastq_file.write(self.qualstr.decode() + "\n")

    def get_fastq_str(self, bint convert_to_phred=False):
        sio = cStringIO.StringIO()
        self.write_to_fastq_file(sio, convert_to_phred)
        return sio.getvalue()

    cpdef SequenceWithQualities get_reverse_complement(self, bint rename=True):
        cdef SequenceWithQualities res
        if rename:
            res = SequenceWithQualities(
                reverse_complement(self.seq),
                "revcomp_of_" + self.name,
                self._qualstr[::-1],
                self._qualscale)
        else:
            res = SequenceWithQualities(
                reverse_complement(self.seq),
                self.name,
                self._qualstr[::-1],
                self._qualscale)
        if self._qualarr is not None:
            res._qualarr = self._qualarr[::-1]
        return res

    cpdef object add_qual_to_count_array(SequenceWithQualities self,
                                         numpy.ndarray count_array_):

        cdef numpy.ndarray[numpy.int_t, ndim = 2] count_array = count_array_
        if self._qualarr is None:
            self._fill_qual_arr()
        cdef numpy.ndarray[numpy.uint8_t, ndim = 1] qual_array = self._qualarr

        cdef numpy.npy_intp seq_length = numpy.PyArray_DIMS(qual_array)[0]
        cdef numpy.npy_intp qual_size = numpy.PyArray_DIMS(count_array)[1]

        if seq_length > numpy.PyArray_DIMS(count_array)[0]:
            raise ValueError("'count_array' too small for sequence.")

        cdef numpy.npy_intp i
        cdef numpy.npy_int q
        for i in range(seq_length):
            q = qual_array[i]
            if(q >= qual_size):
                raise ValueError("Too large quality value encountered.")
            count_array[i, q] += 1

        return None

    cpdef SequenceWithQualities trim_left_end_with_quals(SequenceWithQualities self,
                                                         Sequence pattern, int max_mm_qual=5):
        cdef int seqlen = len(self.seq)
        cdef int patlen = len(pattern.seq)
        cdef int minlen
        if seqlen < patlen:
            minlen = seqlen
        else:
            minlen = patlen
        cdef char * seq_cstr = self.seq
        cdef char * pat_cstr = pattern.seq
        cdef int match = 0
        cdef int i, j
        cdef int sum_mm_qual
        if self._qualarr is None:
            self._fill_qual_arr()
        cdef numpy.ndarray[numpy.uint8_t, ndim = 1] qual_array = self._qualarr
        for i in range(1, minlen + 1):
            num_mismatches = 0
            for j in range(i):
                if seq_cstr[j] != pat_cstr[patlen - i + j]:
                    sum_mm_qual += qual_array[j]
                    if sum_mm_qual > max_mm_qual:
                        break
            else:
                match = i
        return self[match: seqlen]

    cpdef SequenceWithQualities trim_right_end_with_quals(SequenceWithQualities self,
                                                          Sequence pattern, int max_mm_qual=5):
        cdef int seqlen = len(self.seq)
        cdef int patlen = len(pattern.seq)
        cdef int minlen
        if seqlen < patlen:
            minlen = seqlen
        else:
            minlen = patlen
        cdef char * seq_cstr = self.seq
        cdef char * pat_cstr = pattern.seq
        cdef int match = 0
        cdef int i, j
        cdef int sum_mm_qual
        if self._qualarr is None:
            self._fill_qual_arr()
        cdef numpy.ndarray[numpy.uint8_t, ndim = 1] qual_array = self._qualarr
        for i in range(1, minlen + 1):
            sum_mm_qual = 0
            for j in range(i):
                if seq_cstr[seqlen - i + j] != pat_cstr[j]:
                    sum_mm_qual += qual_array[seqlen - i + j]
                    if sum_mm_qual > max_mm_qual:
                        break
            else:
                match = i
        return self[0: seqlen - match]


###########################
# CIGAR codes (SAM format)
###########################
_re_cigar_codes = re.compile('([MIDNSHP=X])')

cigar_operation_names = {
    'M': 'matched',
    'I': 'inserted',
    'D': 'deleted',
    'N': 'skipped',
    'S': 'soft-clipped',
    'H': 'hard-clipped',
    'P': 'padded',
    '=': 'sequence-matched',
    'X': 'sequence-mismatched'}


cigar_operation_codes = ['M', 'I', 'D', 'N', 'S', 'H', 'P', '=', 'X']
cigar_operation_code_dict = dict(
    [(x, i) for i, x in enumerate(cigar_operation_codes)])


cdef class CigarOperation(object):

    cdef public str type
    cdef public int size
    cdef public GenomicInterval ref_iv
    cdef public int query_from, query_to

    def __init__(self, str type_, int size, int rfrom, int rto, int qfrom,
                 int qto, str chrom, str strand, bint check=True):
        self.type = type_
        self.size = size
        self.ref_iv = GenomicInterval(chrom, rfrom, rto, strand)
        self.query_from = qfrom
        self.query_to = qto
        if check and not self.check():
            raise ValueError("Inconsistent CIGAR operation.")

    def __repr__(self):
        return "< %s: %d base(s) %s on ref iv %s, query iv [%d,%d) >" % (
            self.__class__.__name__, self.size, cigar_operation_names[
                self.type],
            str(self.ref_iv), self.query_from, self.query_to)

    def check(CigarOperation self):
        cdef int qlen = self.query_to - self.query_from
        cdef int rlen = self.ref_iv.length
        if self.type == 'M' or self.type == '=' or self.type == 'X':
            if not (qlen == self.size and rlen == self.size):
                return False
        elif self.type == 'I' or self.type == 'S':
            if not (qlen == self.size and rlen == 0):
                return False
        elif self.type == 'D' or self.type == 'N':
            if not (qlen == 0 and rlen == self.size):
                return False
        elif self.type == 'H' or self.type == 'P':
            if not (qlen == 0 and rlen == 0):
                return False
        else:
            return False
        return True


cpdef list parse_cigar(str cigar_string, int ref_left=0, str chrom="", str strand="."):
    cdef list split_cigar, cl
    cdef int size
    cdef str code
    split_cigar = _re_cigar_codes.split(cigar_string)
    if split_cigar[-1] != '' or len(split_cigar) % 2 != 1:
        raise ValueError("Illegal CIGAR string '%s'" % cigar_string)
    cl = []
    for i in range(len(split_cigar) // 2):
        try:
            size = int(split_cigar[2 * i])
        except ValueError:
            raise ValueError("Illegal CIGAR string '%s'" % cigar_string)
        code = split_cigar[2 * i + 1]
        cl.append((code, size))
    return build_cigar_list(cl, ref_left, chrom, strand)


cpdef list build_cigar_list(list cigar_pairs, int ref_left=0, str chrom="", str strand="."):
    cdef list split_cigar, res
    cdef int rpos, qpos, size
    cdef str code
    rpos = ref_left
    qpos = 0
    res = []
    for code, size in cigar_pairs:
        if code == 'M' or code == '=' or code == 'X':
            res.append(CigarOperation(
                code, size, rpos, rpos + size, qpos, qpos + size, chrom, strand))
            rpos += size
            qpos += size
        elif code == 'I':
            res.append(CigarOperation(
                'I', size, rpos, rpos, qpos, qpos + size, chrom, strand))
            qpos += size
        elif code == 'D':
            res.append(CigarOperation(
                'D', size, rpos, rpos + size, qpos, qpos, chrom, strand))
            rpos += size
        elif code == 'N':
            res.append(CigarOperation(
                'N', size, rpos, rpos + size, qpos, qpos, chrom, strand))
            rpos += size
        elif code == 'S':
            res.append(CigarOperation(
                'S', size, rpos, rpos, qpos, qpos + size, chrom, strand))
            qpos += size
        elif code == 'H':
            res.append(CigarOperation(
                'H', size, rpos, rpos, qpos, qpos, chrom, strand))
        elif code == 'P':
            res.append(CigarOperation(
                'P', size, rpos, rpos, qpos, qpos, chrom, strand))
        else:
            raise ValueError("Unknown CIGAR code '%s' encountered." % code)
    return res


###########################
# Alignment
###########################
cdef class Alignment(object):
    """An aligned read (typically from a BAM file).

    An alignment object can be defined in different ways but will always
    provide these attributes:
      read:      a SequenceWithQualities object with the read
      aligned:   whether the read is aligned
      iv:        a GenomicInterval object with the alignment position
    """

    def __init__(self, read, iv):
        self._read = read
        self.iv = iv

    @property
    def read(self):
        return self._read

    def __repr__(self):
        cdef str s
        if self.paired_end:
            s = "Paired-end read"
        else:
            s = "Read"
        if self.aligned:
            return "<%s object: %s '%s' aligned to %s>" % (
                self.__class__.__name__, s, self.read.name, str(self.iv))
        else:
            return "<%s object: %s '%s', not aligned>" % (
                self.__class__.__name__, s, self.read.name)

    @property
    def paired_end(self):
        return False

    @property
    def aligned(self):
        """Returns True unless self.iv is None. The latter indicates that
        this record decribes a read for which no alignment was found.
        """
        return self.iv is not None


cdef class AlignmentWithSequenceReversal(Alignment):
    """Many aligners report the read's sequence in reverse-complemented form
    when it was mapped to the reverse strand. For such alignments, a
    daughter class of this one should be used.

    Then, the read is stored as aligned in the 'read_as_aligned' field,
    and get reverse-complemented back to the sequenced form when the 'read'
    attribute is sequenced.
    """

    def __init__(self, SequenceWithQualities read_as_aligned, GenomicInterval iv):
        self.read_as_aligned = read_as_aligned
        self._read_as_sequenced = None
        self.iv = iv

    property read:
        def __get__(self):
            if self._read_as_sequenced is None:
                if (not self.aligned) or self.iv.strand != "-":
                    self._read_as_sequenced = self.read_as_aligned
                else:
                    self._read_as_sequenced = self.read_as_aligned.get_reverse_complement()
                    self._read_as_sequenced.name = self.read_as_aligned.name
            return self._read_as_sequenced
        # def __set__( self, read ):
        #   self.read_as_aligned = read
        #   self._read_as_sequenced = None


cdef class BowtieAlignment(AlignmentWithSequenceReversal):
    """When reading in a Bowtie file, objects of the class BowtieAlignment
    are returned. In addition to the 'read' and 'iv' fields (see Alignment
    class), the fields 'reserved' and 'substitutions' are provided. These
    contain the content of the respective columns of the Bowtie output

    [A parser for the substitutions field will be added soon.]
    """

    cdef public str reserved
    cdef public str substitutions

    def __init__(self, bowtie_line):
        cdef str readId, strand, chrom, position, read, qual
        cdef int positionint
        (readId, strand, chrom, position, read, qual,
         self.reserved, self.substitutions) = bowtie_line.split('\t')
        positionint = int(position)
        AlignmentWithSequenceReversal.__init__(self,
                                               SequenceWithQualities(
                                                   read, readId, qual),
                                               GenomicInterval(chrom, positionint, positionint + len(read), strand))


cdef _parse_SAM_optional_field_value(str field):
    if len(field) < 5 or field[2] != ':' or field[4] != ':':
        raise ValueError("Malformatted SAM optional field '%'" % field)
    if field[3] == 'A':
        return field[5]
    elif field[3] == 'i':
        return int(field[5:])
    elif field[3] == 'f':
        return float(field[5:])
    elif field[3] == 'Z':
        return field[5:]
    elif field[3] == 'H':
        return int(field[5:], 16)
    elif field[3] == 'B':
        if field[5] == 'f':
            return numpy.array(field[7:].split(','), float)
        else:
            return numpy.array(field[7:].split(','), int)
    else:
        raise ValueError("SAM optional field with illegal type letter '%s'" % field[2])


cdef class SAM_Alignment(AlignmentWithSequenceReversal):
    """When reading in a SAM file, objects of the class SAM_Alignment
    are returned. In addition to the 'read', 'iv' and 'aligned' fields (see
    Alignment class), the following fields are provided:
     - aQual: the alignment quality score
     - cigar: a list of CigarOperatio objects, describing the alignment
     - tags: the extra information tags [not yet implemented]
    """

    def to_pysam_AlignedSegment(self, sf):
        try:
            import pysam
        except ImportError:
            sys.stderr.write(
                "Please Install PySam to use this functionality (http://code.google.com/p/pysam/)")
            raise

        a = pysam.AlignedSegment()
        a.query_sequence = self.read.seq if self.iv == None or self.iv.strand == '+' else self.read.get_reverse_complement().seq
        a.query_qualities = self.read.qual if self.iv == None or self.iv.strand == '+' else self.read.get_reverse_complement().qual
        a.query_name = self.read.name
        a.flag = self.flag
        a.tags = self.optional_fields
        if self.aligned:
            a.cigartuples = [(cigar_operation_code_dict[c.type], c.size)
                             for c in self.cigar]
            a.reference_start = self.iv.start
            a.reference_id = sf.gettid(self.iv.chrom)
            a.template_length = self.inferred_insert_size
            a.mapping_quality = self.aQual
        else:
            a.reference_start = -1
            a.reference_id = -1
        if self.mate_aligned:
            a.next_reference_id = sf.gettid(self.mate_start.chrom)
            a.next_reference_start = self.mate_start.start
        else:
            a.next_reference_id = -1
            a.next_reference_start = -1
        return a

    def to_pysam_AlignedRead(self, sf):
        try:
            import pysam
        except ImportError:
            sys.stderr.write(
                "Please Install PySam to use this functionality (http://code.google.com/p/pysam/)")
            raise

        a = pysam.AlignedRead()
        a.seq = self.read.seq
        a.qual = self.read.qualstr
        a.qname = self.read.name
        a.flag = self.flag
        a.tags = self.optional_fields
        if self.aligned:
            a.cigar = [(cigar_operation_code_dict[c.type], c.size)
                       for c in self.cigar]
            a.pos = self.iv.start
            a.tid = sf.gettid(self.iv.chrom)
            a.isize = self.inferred_insert_size
            a.mapq = self.aQual
        else:
            a.pos = -1
            a.tid = -1
        if self.mate_aligned:
            a.mrnm = sf.gettid(self.mate_start.chrom)
            a.mpos = self.mate_start.start
        else:
            a.mrnm = -1
            a.mpos = -1
        return a

    @classmethod
    def from_pysam_AlignedRead(cls, read, samfile):
        strand = "-" if read.is_reverse else "+"
        if not read.is_unmapped:
            chrom = samfile.getrname(read.tid)
            iv = GenomicInterval(chrom, read.pos, read.aend, strand)
        else:
            iv = None
        if (read.qual is None) or (read.qual == "*"):
            seq = SequenceWithQualities(
                read.query_sequence.encode(), read.qname, b'',
                "noquals")
        else:
            seq = SequenceWithQualities(
                read.query_sequence.encode(), read.qname, read.qual.encode(),
                )

        a = SAM_Alignment(seq, iv)
        a.cigar = build_cigar_list([(cigar_operation_codes[code], length) for (
            code, length) in read.cigar], read.pos, chrom, strand) if iv != None else []
        a.inferred_insert_size = read.isize
        a.aQual = read.mapq
        a.flag = read.flag
        a.proper_pair = read.is_proper_pair
        a.not_primary_alignment = read.is_secondary
        a.failed_platform_qc = read.is_qcfail
        a.pcr_or_optical_duplicate = read.is_duplicate
        a.supplementary = read.is_supplementary
        a.original_sam_line = ""
        a.optional_fields = read.tags
        if read.is_paired:
            # These two should be but are not always consistent
            if (not read.mate_is_unmapped) and (read.mrnm != -1):
                strand = "-" if read.mate_is_reverse else "+"
                a.mate_start = GenomicPosition(
                    samfile.getrname(read.mrnm), read.mpos, strand)
            else:
                a.mate_start = None
            if read.is_read1:
                a.pe_which = intern("first")
            elif read.is_read2:
                a.pe_which = intern("second")
            else:
                a.pe_which = intern("unknown")
        else:
            a.pe_which = intern("not_paired_end")
        return a

    @classmethod
    def from_pysam_AlignedSegment(cls, read, samfile):
        strand = "-" if read.is_reverse else "+"
        if not read.is_unmapped:
            chrom = samfile.getrname(read.tid)
            iv = GenomicInterval(chrom, read.reference_start,
                                 read.reference_end, strand)
        else:
            iv = None

        # read.query_sequence can be empty (e.g. nanopore runs), then pysam
        # casts it as None or *. We recast it as an empty string to preserve
        #types. It is then converted to ASCII
        query_sequence = read.query_sequence
        if (query_sequence is None) or (query_sequence == '*'):
            query_sequence = ''
        query_sequence = query_sequence.encode()

        # read.qual can be empty (e.g. special filtering, artificial), then
        # it comes through as None or as a * (see previous comment). In this
        # case, we cast it as an empty ASCII _and_ we have to tell the
        # class about the issue.
        if (read.qual is None) or (read.qual == "*"):
            seq = SequenceWithQualities(
                query_sequence, read.query_name, b'',
                'noquals')
        else:
            seq = SequenceWithQualities(
                query_sequence, read.qname, read.qual.encode(),
                )

        a = SAM_Alignment(seq, iv)
        a.cigar = build_cigar_list([(cigar_operation_codes[code], length) for (
            code, length) in read.cigartuples], read.reference_start, chrom, strand) if iv != None else []
        a.inferred_insert_size = read.template_length
        a.aQual = read.mapping_quality
        a.flag = read.flag
        a.proper_pair = read.is_proper_pair
        a.not_primary_alignment = read.is_secondary
        a.failed_platform_qc = read.is_qcfail
        a.pcr_or_optical_duplicate = read.is_duplicate
        a.supplementary = read.is_supplementary
        a.original_sam_line = ""
        a.optional_fields = read.tags
        if read.is_paired:
            # These two should be but are not always consistent
            if (not read.mate_is_unmapped) and (read.mrnm != -1):
                strand = "-" if read.mate_is_reverse else "+"
                a.mate_start = GenomicPosition(samfile.getrname(
                    read.mrnm), read.next_reference_start, strand)
            else:
                a.mate_start = None
            if read.is_read1:
                a.pe_which = intern("first")
            elif read.is_read2:
                a.pe_which = intern("second")
            else:
                a.pe_which = intern("unknown")
        else:
            a.pe_which = intern("not_paired_end")
        return a

    @classmethod
    def from_SAM_line(cls, line):
        cdef str qname, flag, rname, pos, mapq, cigar,
        cdef str mrnm, mpos, isize, seq, qual
        cdef list optional_fields
        cdef int posint, flagint
        cdef str strand
        cdef list cigarlist
        cdef SequenceWithQualities swq

        fields = line.rstrip().split("\t")
        if len(fields) < 10:
            raise ValueError("SAM line does not contain at least 11 tab-delimited fields.")
        (qname, flag, rname, pos, mapq, cigar, mrnm, mpos, isize,
         seq, qual) = fields[0:11]
        optional_fields = fields[11:]

        if seq.count("=") > 0:
            raise ValueError("Sequence in SAM file contains '=', which is not supported.")
        if seq.count(".") > 0:
            raise ValueError("Sequence in SAM file contains '.', which is not supported.")
        flagint = int(flag)

        if flagint & 0x0004:     # flag "query sequence is unmapped"
            iv = None
            cigarlist = None
        else:
            if rname == "*":
                raise ValueError("Malformed SAM line: RNAME == '*' although flag bit &0x0004 cleared")
            # SAM is one-based, but HTSeq is zero-based!
            posint = int(pos) - 1
            if flagint & 0x0010:      # flag "strand of the query"
                strand = "-"
            else:
                strand = "+"
            cigarlist = parse_cigar(cigar, posint, rname, strand)
            iv = GenomicInterval(
                rname, posint, cigarlist[-1].ref_iv.end, strand)

        if qual != "*":
            swq = SequenceWithQualities(
                seq.upper().encode(), qname, qual.upper().encode())
        else:
            swq = SequenceWithQualities(
                seq.upper().encode(), qname, b"", "noquals")

        alnmt = SAM_Alignment(swq, iv)
        alnmt.flag = flagint
        alnmt.cigar = cigarlist
        alnmt.optional_fields = [
            (field[:2], _parse_SAM_optional_field_value(field)) for field in optional_fields]
        alnmt.aQual = int(mapq)
        alnmt.inferred_insert_size = int(isize)
        alnmt.original_sam_line = line

        if flagint & 0x0001:         # flag "read is paired in sequencing"
            if flagint & 0x0008:      # flag "mate is unmapped"
                alnmt.mate_start = None
            else:
                if mrnm == "*":
                    raise ValueError("Malformed SAM line: MRNM == '*' although flag bit &0x0008 cleared")
                posint = int(mpos) - 1
                if flagint & 0x0020:   # flag "strand of the mate"
                    strand = "-"
                else:
                    strand = "+"
                alnmt.mate_start = GenomicPosition(mrnm, posint, strand)
                if alnmt.mate_start.chrom == "=":
                    if alnmt.iv is not None:
                        alnmt.mate_start.chrom = alnmt.iv.chrom
            if flagint & 0x0040:
                alnmt.pe_which = intern("first")
            elif flagint & 0x0080:
                alnmt.pe_which = intern("second")
            else:
                alnmt.pe_which = intern("unknown")
        else:
            alnmt.mate_start = None
            alnmt.pe_which = intern("not_paired_end")

        alnmt.proper_pair = flagint & 0x0002 > 0
        alnmt.not_primary_alignment = flagint & 0x0100 > 0
        alnmt.failed_platform_qc = flagint & 0x0200 > 0
        alnmt.pcr_or_optical_duplicate = flagint & 0x0400 > 0
        alnmt.supplementary = flagint & 0x0800 > 0

        return alnmt

    property flag:
        def __get__(self):
            return self._flag

        def __set__(self, value):
            self._flag = value

    @property
    def paired_end(self):
        return self.pe_which != "not_paired_end"

    @property
    def mate_aligned(self):
        return self.mate_start is not None

    def get_sam_line(self):
        cdef str cigar = ""
        cdef GenomicInterval query_start, mate_start
        cdef CigarOperation cop

        if self.aligned:
            query_start = self.iv
        else:
            query_start = GenomicPosition("*", -1)

        if self.mate_start is not None:
            mate_start = self.mate_start
        else:
            mate_start = GenomicPosition("*", -1)

        if self.cigar is not None:
            for cop in self.cigar:
                cigar += str(cop.size) + cop.type
        else:
            cigar = "*"

        return '\t'.join(
                (self.read.name,
                 str(self.flag),
                 query_start.chrom,
                 str(query_start.start + 1),
                 str(self.aQual),
                 cigar,
                 mate_start.chrom,
                 str(mate_start.pos + 1),
                 str(self.inferred_insert_size),
                 self.read_as_aligned.seq.decode(),
                 self.read_as_aligned.qualstr.decode(),
                 '\t'.join(self.raw_optional_fields())))

    def has_optional_field(SAM_Alignment self, str tag):
        '''Check if this alignment has the specified optional field

        Args:
            tag: the field to look for.
        Returns: a bool with True if the field has been found, False otherwise.
        '''
        for p in self.optional_fields:
            if p[0] == tag:
                return True
        return False

    def optional_field(SAM_Alignment self, str tag):
        res = [p for p in self.optional_fields if p[0] == tag]
        if len(res) == 1:
            return res[0][1]
        else:
            if len(res) == 0:
                raise KeyError("SAM optional field tag %s not found" % tag)
            else:
                raise ValueError("SAM optional field tag %s not unique" % tag)

    def raw_optional_fields(self):
        res = []
        for op in self.optional_fields:
            if op[1].__class__ == str:
                if len(op[1]) == 1:
                    tc = "A"
                else:
                    tc = "Z"
            elif op[1].__class__ == int:
                tc = "i"
            elif op[1].__class__ == float:
                tc = "f"
            else:
                tc = "H"
            res.append(":".join([op[0], tc, str(op[1])]))
        return res


###########################
# Helpers
###########################
cpdef list quotesafe_split(bytes s, bytes split=b';', bytes quote=b'"'):
    cdef list l = []
    cdef int i = 0
    cdef int begin_token = 0
    cdef bint in_quote = False
    cdef char * s_c = s
    cdef char split_c = split[0]
    cdef char quote_c = quote[0]
    if len(split) != 1:
        raise ValueError("'split' must be length 1")
    if len(quote) != 1:
        raise ValueError("'quote' must be length 1")
    while s_c[i] != 0:
        if s_c[i] == quote_c:
            in_quote = not in_quote
        elif (not in_quote) and s_c[i] == split_c:
            l.append(s[begin_token: i])
            begin_token = i + 1
        i += 1
    l.append(s[begin_token:])
    if in_quote:
        raise ValueError("unmatched quote")
    return l
