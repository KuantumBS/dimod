# Copyright 2021 D-Wave Systems Inc.
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

from numbers import Number

from cpython.long cimport PyLong_Check
from cpython.dict cimport PyDict_Size, PyDict_Contains
from cpython.ref cimport PyObject

from dimod.utilities import iter_safe_relabels

cdef extern from "Python.h":
    # not yet available as of cython 0.29.22
    PyObject* PyDict_GetItemWithError(object p, object key) except? NULL


cdef class cyVariables:
    def __init__(self, object iterable=None):
        self._index_to_label = dict()
        self._label_to_index = dict()
        self._stop = 0

        if iterable is not None:
            self._extend(iterable, permissive=True)

    def __contains__(self, v):
        return bool(self.count(v))

    # todo: support slices
    def __getitem__(self, Py_ssize_t idx):
        if idx < 0:
            idx = self._stop + idx

        if idx >= self._stop:
            raise IndexError('index out of range')

        cdef object v
        cdef object pyidx = idx
        cdef PyObject* obj
        if self._is_range():
            v = pyidx
        else:
            # I am reasonably confident that this is safe and it's faster
            # than self._index_to_label.get
            obj = PyDict_GetItemWithError(self._index_to_label, pyidx)
            if obj == NULL:
                v = pyidx
            else:
                v = <object>obj

        return v

    def __len__(self):
        return self._stop

    cpdef object _append(self, object v=None, bint permissive=False):
        """Append a new variable.

        This method is semi-public. it is intended to be used by
        classes that have :class:`.Variables` as an attribute, not by the
        the user.
        """
        if v is None:
            v = self._stop

            if not self._is_range() and self.count(v):
                v = 0
                while self.count(v):
                    v += 1

        elif self.count(v):
            if permissive:
                return v
            else:
                raise ValueError('{!r} is already a variable'.format(v))

        idx = self._stop

        if idx != v:
            self._label_to_index[v] = idx
            self._index_to_label[idx] = v

        self._stop += 1
        return v

    cpdef bint _is_range(self):
        """Return whether the Variables are current labelled [0, n)."""
        return not PyDict_Size(self._label_to_index)

    cpdef object _extend(self, object iterable, bint permissive=False):
        """Add new variables.

        This method is semi-public. it is intended to be used by
        classes that have :class:`.Variables` as an attribute, not by the
        the user.
        """
        # todo: performance improvements for range etc
        for v in iterable:
            self._append(v, permissive=permissive)

    def _pop(self):
        """Remove the last variable.

        This method is semi-public. it is intended to be used by
        classes that have :class:`.Variables` as an attribute, not by the
        the user.
        """
        if not self:
            raise IndexError("Cannot pop when Variables is empty")

        self._stop = idx = self._stop - 1

        label = self._index_to_label.pop(idx, idx)
        self._label_to_index.pop(label, None)
        return label

    def _relabel(self, mapping):
        """Relabel the variables in-place.

        This method is semi-public. it is intended to be used by
        classes that have :class:`.Variables` as an attribute, not by the
        the user.
        """
        for submap in iter_safe_relabels(mapping, self):
            for old, new in submap.items():
                if old == new:
                    continue

                idx = self._label_to_index.pop(old, old)

                if new != idx:
                    self._label_to_index[new] = idx
                    self._index_to_label[idx] = new  # overwrites old idx
                else:
                    self._index_to_label.pop(idx, None)

    def _relabel_as_integers(self):
        """Relabel the variables as integers in-place.

        This method is semi-public. it is intended to be used by
        classes that have :class:`.Variables` as an attribute, not by the
        the user.
        """
        mapping = self._index_to_label.copy()
        self._index_to_label.clear()
        self._label_to_index.clear()
        return mapping

    cdef Py_ssize_t _count_int(self, object v) except -1:
        # only works when v is an int
        cdef Py_ssize_t vi = v

        if self._is_range():
            return 0 <= vi < self._stop

        # need to make sure that we're not using the integer elsewhere
        return (0 <= vi < self._stop
                and not PyDict_Contains(self._index_to_label, v)
                or PyDict_Contains(self._label_to_index, v))

    cpdef Py_ssize_t count(self, object v) except -1:
        """Return the number of times `v` appears in Variables.

        Because the variables are always unique, this will always return 1 or 0.
        """
        if PyLong_Check(v):
            return self._count_int(v)

        # handle other numeric types
        if isinstance(v, Number):
            v_int = int(v)  # assume this is safe...
            if v_int == v:
                return self._count_int(v_int)  # it's an integer afterall!

        try:
            return v in self._label_to_index
        except TypeError:
            # unhashable
            return False

    cpdef Py_ssize_t index(self, object v, bint permissive=False) except -1:
        """Return the index of `v`.

        Args:
            v (hashable):
                A variable.

            permissive (bool, optional, default=False):
                If True, the variable will be inserted, guaranteeing an index
                can be returned.

        Returns:
            int: The index of the given variable.

        Raises:
            ValueError: If the variable is not present and `permissive` is
            False.

        """
        if permissive:
            self._append(v, permissive=True)
        if not self.count(v):
            raise ValueError('unknown variable {!r}'.format(v))

        if self._is_range():
            return v if PyLong_Check(v) else int(v)

        # I am reasonably confident that this is safe and it's faste
        # than self._label_to_index.get
        cdef PyObject* obj = PyDict_GetItemWithError(self._label_to_index, v)
        if obj == NULL:
            pyobj = v
        else:
            pyobj = <object>obj

        return pyobj if PyLong_Check(pyobj) else int(pyobj)
