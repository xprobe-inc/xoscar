# distutils: language = c++
# Copyright 2022-2023 XProbe Inc.
# derived from copyright 1999-2021 Alibaba Group Holding Ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import asyncio
import collections
import dataclasses
import functools
import importlib
import inspect
import io
import itertools
import logging
import numbers
import os
import sys
import time
import warnings
import pkgutil
from abc import ABC
from functools import partial
from random import getrandbits
from weakref import WeakSet
from types import TracebackType
from typing import (
    AsyncGenerator,
    Callable,
    Dict,
    Optional,
    List,
    Tuple,
    Type,
    Union,
)

from libc.stdint cimport uint_fast64_t
from libc.stdlib cimport free, malloc

from .core cimport ActorRef, LocalActorRef
from .libcpp cimport mt19937_64

# Please refer to https://bugs.python.org/issue41451
try:

    class _Dummy(ABC):
        __slots__ = ("__weakref__",)

    abc_type_require_weakref_slot = True
except TypeError:
    abc_type_require_weakref_slot = False


cdef class Timer:
    cdef object _start
    cdef readonly object duration

    def __enter__(self):
        self._start = time.time()
        return self

    def __exit__(self, *_):
        self.duration = time.time() - self._start


cdef mt19937_64 _rnd_gen
cdef bint _rnd_is_seed_set = False
_type_dispatchers = WeakSet()
NamedType = collections.namedtuple("NamedType", ["name", "type_"])
logger = logging.getLogger(__name__)


cdef class TypeDispatcher:
    def __init__(self):
        self._handlers = dict()
        self._lazy_handlers = dict()
        # store inherited handlers to facilitate unregistering
        self._inherit_handlers = dict()

        _type_dispatchers.add(self)

    cpdef void register(self, object type_, object handler):
        if isinstance(type_, str):
            self._lazy_handlers[type_] = handler
        elif type(type_) is not NamedType and isinstance(type_, tuple):
            for t in type_:
                self.register(t, handler)
        else:
            self._handlers[type_] = handler

    cpdef void unregister(self, object type_):
        if type(type_) is not NamedType and isinstance(type_, tuple):
            for t in type_:
                self.unregister(t)
        else:
            self._lazy_handlers.pop(type_, None)
            self._handlers.pop(type_, None)
            self._inherit_handlers.clear()

    cdef _reload_lazy_handlers(self):
        for k, v in self._lazy_handlers.items():
            mod_name, obj_name = k.rsplit('.', 1)
            with warnings.catch_warnings():
                # the lazy imported cudf will warn no device found,
                # when we set visible device to -1 for CPU processes,
                # ignore the warning to not distract users
                warnings.simplefilter("ignore")
                mod = importlib.import_module(mod_name, __name__)
            self.register(getattr(mod, obj_name), v)
        self._lazy_handlers = dict()

    cpdef get_handler(self, object type_):
        try:
            return self._handlers[type_]
        except KeyError:
            pass

        try:
            return self._inherit_handlers[type_]
        except KeyError:
            self._reload_lazy_handlers()
            if type(type_) is NamedType:
                named_type = partial(NamedType, type_.name)
                mro = itertools.chain(
                    *zip(map(named_type, type_.type_.__mro__),
                         type_.type_.__mro__)
                )
            else:
                mro = type_.__mro__
            for clz in mro:
                # only lookup self._handlers for mro clz
                handler = self._handlers.get(clz)
                if handler is not None:
                    self._inherit_handlers[type_] = handler
                    return handler
            raise KeyError(f'Cannot dispatch type {type_}')

    def __call__(self, object obj, *args, **kwargs):
        return self.get_handler(type(obj))(obj, *args, **kwargs)

    @staticmethod
    def reload_all_lazy_handlers():
        for dispatcher in _type_dispatchers:
            (<TypeDispatcher>dispatcher)._reload_lazy_handlers()


cpdef str to_str(s, encoding='utf-8'):
    if type(s) is str:
        return <str>s
    elif isinstance(s, bytes):
        return (<bytes>s).decode(encoding)
    elif isinstance(s, str):
        return str(s)
    elif s is None:
        return s
    else:
        raise TypeError(f"Could not convert from {s} to str.")


cpdef bytes to_binary(s, encoding='utf-8'):
    if type(s) is bytes:
        return <bytes>s
    elif isinstance(s, unicode):
        return (<unicode>s).encode(encoding)
    elif isinstance(s, bytes):
        return bytes(s)
    elif s is None:
        return None
    else:
        raise TypeError(f"Could not convert from {s} to bytes.")


cpdef void reset_id_random_seed() except *:
    cdef bytes seed_bytes
    global _rnd_is_seed_set

    seed_bytes = getrandbits(64).to_bytes(8, "little")
    _rnd_gen.seed((<uint_fast64_t *><char *>seed_bytes)[0])
    _rnd_is_seed_set = True


cpdef bytes new_random_id(int byte_len):
    cdef uint_fast64_t *res_ptr
    cdef uint_fast64_t res_data[4]
    cdef int i, qw_num = byte_len >> 3
    cdef bytes res

    if not _rnd_is_seed_set:
        reset_id_random_seed()

    if (qw_num << 3) < byte_len:
        qw_num += 1

    if qw_num <= 4:
        # use stack memory to accelerate
        res_ptr = res_data
    else:
        res_ptr = <uint_fast64_t *>malloc(qw_num << 3)

    try:
        for i in range(qw_num):
            res_ptr[i] = _rnd_gen()
        return <bytes>((<char *>&(res_ptr[0]))[:byte_len])
    finally:
        # free memory if allocated by malloc
        if res_ptr != res_data:
            free(res_ptr)


cpdef bytes new_actor_id():
    return new_random_id(32)


def create_actor_ref(*args, **kwargs):
    """
    Create an actor reference.

    Returns
    -------
    ActorRef
    """

    cdef str address
    cdef object uid
    cdef ActorRef existing_ref

    address = to_str(kwargs.pop('address', None))
    uid = kwargs.pop('uid', None)

    if kwargs:
        raise ValueError('Only `address` or `uid` keywords are supported')

    if len(args) == 2:
        if address:
            raise ValueError('address has been specified')
        address = to_str(args[0])
        uid = args[1]
    elif len(args) == 1:
        tp0 = type(args[0])
        if tp0 is ActorRef or tp0 is LocalActorRef:
            existing_ref = <ActorRef>(args[0])
            uid = existing_ref.uid
            address = to_str(address or existing_ref.address)
        else:
            uid = args[0]

    if uid is None:
        raise ValueError('Actor uid should be provided')

    return ActorRef(address, uid)


cdef set _is_async_generator_typecache = set()


cdef bint is_async_generator(obj):
    cdef type tp = type(obj)
    if tp in _is_async_generator_typecache:
        return True

    if isinstance(obj, AsyncGenerator):
        if len(_is_async_generator_typecache) < 100:
            _is_async_generator_typecache.add(tp)
        return True
    else:
        return False

_memory_size_indices = {"": 0, "k": 1, "m": 2, "g": 3, "t": 4}

def parse_readable_size(value: Union[str, int, float]) -> Tuple[float, bool]:
    if isinstance(value, numbers.Number):
        return float(value), False

    value = value.strip().lower()
    num_pos = 0
    while num_pos < len(value) and value[num_pos] in "0123456789.-":
        num_pos += 1

    value, suffix = value[:num_pos], value[num_pos:]
    suffix = suffix.strip()
    if suffix.endswith("%"):
        return float(value) / 100, True

    try:
        return float(value) * (1024 ** _memory_size_indices[suffix[:1]]), False
    except (ValueError, KeyError):
        raise ValueError(f"Unknown limitation value: {value}")


def wrap_exception(
    exc: Exception,
    bases: Tuple[Type] = None,
    wrap_name: str = None,
    message: str = None,
    traceback: Optional[TracebackType] = None,
    attr_dict: dict = None,
) -> Exception:
    """Generate an exception wraps the cause exception."""

    def __init__(self):
        pass

    def __getattr__(self, item):
        return getattr(exc, item)

    def __str__(self):
        return message or super(type(self), self).__str__()

    traceback = traceback or exc.__traceback__
    bases = bases or ()
    attr_dict = attr_dict or {}
    attr_dict.update(
        {
            "__init__": __init__,
            "__getattr__": __getattr__,
            "__str__": __str__,
            "__wrapname__": wrap_name,
            "__wrapped__": exc,
            "__module__": type(exc).__module__,
            "__cause__": exc.__cause__,
            "__context__": exc.__context__,
            "__suppress_context__": exc.__suppress_context__,
            "args": exc.args,
        }
    )
    new_exc_type = type(type(exc).__name__, bases + (type(exc),), attr_dict)
    return new_exc_type().with_traceback(traceback)


# from https://github.com/ericvsmith/dataclasses/blob/master/dataclass_tools.py
# released under Apache License 2.0
def dataslots(cls):
    # Need to create a new class, since we can't set __slots__
    #  after a class has been created.

    # Make sure __slots__ isn't already set.
    if "__slots__" in cls.__dict__:  # pragma: no cover
        raise TypeError(f"{cls.__name__} already specifies __slots__")

    # Create a new dict for our new class.
    cls_dict = dict(cls.__dict__)
    field_names = tuple(f.name for f in dataclasses.fields(cls))
    cls_dict["__slots__"] = field_names
    for field_name in field_names:
        # Remove our attributes, if present. They'll still be
        #  available in _MARKER.
        cls_dict.pop(field_name, None)
    # Remove __dict__ itself.
    cls_dict.pop("__dict__", None)
    # And finally create the class.
    qualname = getattr(cls, "__qualname__", None)
    cls = type(cls)(cls.__name__, cls.__bases__, cls_dict)
    if qualname is not None:
        cls.__qualname__ = qualname
    return cls


def implements(f: Callable):
    def decorator(g):
        g.__doc__ = f.__doc__
        return g

    return decorator


class classproperty:
    def __init__(self, f):
        self.f = f

    def __get__(self, obj, owner):
        return self.f(owner)


def lazy_import(
    name: str,
    package: str = None,
    globals: Dict = None,  # pylint: disable=redefined-builtin
    locals: Dict = None,  # pylint: disable=redefined-builtin
    rename: str = None,
    placeholder: bool = False,
):
    rename = rename or name
    prefix_name = name.split(".", 1)[0]
    globals = globals or inspect.currentframe().f_back.f_globals

    class LazyModule:
        def __init__(self):
            self._on_loads = []

        def __getattr__(self, item):
            if item.startswith("_pytest") or item in ("__bases__", "__test__"):
                raise AttributeError(item)

            real_mod = importlib.import_module(name, package=package)
            if rename in globals:
                globals[rename] = real_mod
            elif locals is not None:
                locals[rename] = real_mod
            ret = getattr(real_mod, item)
            for on_load_func in self._on_loads:
                on_load_func()
            # make sure on_load hooks only executed once
            self._on_loads = []
            return ret

        def add_load_handler(self, func: Callable):
            self._on_loads.append(func)
            return func

    if pkgutil.find_loader(prefix_name) is not None:
        return LazyModule()
    elif placeholder:
        return ModulePlaceholder(prefix_name)
    else:
        return None


def lazy_import_on_load(lazy_mod):
    def wrapper(fun):
        if lazy_mod is not None and hasattr(lazy_mod, "add_load_handler"):
            lazy_mod.add_load_handler(fun)
        return fun

    return wrapper


class ModulePlaceholder:
    def __init__(self, mod_name: str):
        self._mod_name = mod_name

    def _raises(self):
        raise AttributeError(f"{self._mod_name} is required but not installed.")

    def __getattr__(self, key):
        self._raises()

    def __call__(self, *_args, **_kwargs):
        self._raises()


def patch_asyncio_task_create_time():  # pragma: no cover
    new_loop = False
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = asyncio.new_event_loop()
        new_loop = True
    loop_class = loop.__class__
    # Save raw loop_class.create_task and make multiple apply idempotent
    loop_create_task = getattr(
        patch_asyncio_task_create_time, "loop_create_task", loop_class.create_task
    )
    patch_asyncio_task_create_time.loop_create_task = loop_create_task

    def new_loop_create_task(*args, **kwargs):
        task = loop_create_task(*args, **kwargs)
        task.__mars_asyncio_task_create_time__ = time.time()
        return task

    if loop_create_task is not new_loop_create_task:
        loop_class.create_task = new_loop_create_task
    if not new_loop and loop.create_task is not new_loop_create_task:
        loop.create_task = functools.partial(new_loop_create_task, loop)


async def asyncio_task_timeout_detector(
    check_interval: int, task_timeout_seconds: int, task_exclude_filters: List[str]
):
    task_exclude_filters.append("asyncio_task_timeout_detector")
    while True:  # pragma: no cover
        await asyncio.sleep(check_interval)
        loop = asyncio.get_running_loop()
        current_time = (
            time.time()
        )  # avoid invoke `time.time()` frequently if we have plenty of unfinished tasks.
        for task in asyncio.all_tasks(loop=loop):
            # Some task may be create before `patch_asyncio_task_create_time` applied, take them as never timeout.
            create_time = getattr(
                task, "__mars_asyncio_task_create_time__", current_time
            )
            if current_time - create_time >= task_timeout_seconds:
                stack = io.StringIO()
                task.print_stack(file=stack)
                task_str = str(task)
                if any(
                    excluded_task in task_str for excluded_task in task_exclude_filters
                ):
                    continue
                logger.warning(
                    """Task %s in event loop %s doesn't finish in %s seconds. %s""",
                    task,
                    loop,
                    time.time() - create_time,
                    stack.getvalue(),
                )


def register_asyncio_task_timeout_detector(
    check_interval: int = None,
    task_timeout_seconds: int = None,
    task_exclude_filters: List[str] = None,
) -> Optional[asyncio.Task]:  # pragma: no cover
    """Register a asyncio task which print timeout task periodically."""
    check_interval = check_interval or int(
        os.environ.get("MARS_DEBUG_ASYNCIO_TASK_TIMEOUT_CHECK_INTERVAL", -1)
    )
    if check_interval > 0:
        patch_asyncio_task_create_time()
        task_timeout_seconds = task_timeout_seconds or int(
            os.environ.get("MARS_DEBUG_ASYNCIO_TASK_TIMEOUT_SECONDS", check_interval)
        )
        if not task_exclude_filters:
            # Ignore mars/oscar by default since it has some long-running coroutines.
            task_exclude_filters = os.environ.get(
                "MARS_DEBUG_ASYNCIO_TASK_EXCLUDE_FILTERS", "mars/oscar"
            )
            task_exclude_filters = task_exclude_filters.split(";")
        if sys.version_info[:2] < (3, 7):
            logger.warning(
                "asyncio tasks timeout detector is not supported under python %s",
                sys.version,
            )
        else:
            loop = asyncio.get_running_loop()
            logger.info(
                "Create asyncio tasks timeout detector with check_interval %s task_timeout_seconds %s "
                "task_exclude_filters %s",
                check_interval,
                task_timeout_seconds,
                task_exclude_filters,
            )
            return loop.create_task(
                asyncio_task_timeout_detector(
                    check_interval, task_timeout_seconds, task_exclude_filters
                )
            )
    else:
        return None


def ensure_coverage():
    # make sure coverage is handled when starting with subprocess.Popen
    if (
        not sys.platform.startswith("win") and "COV_CORE_SOURCE" in os.environ
    ):  # pragma: no cover
        try:
            from pytest_cov.embed import cleanup_on_sigterm
        except ImportError:
            pass
        else:
            cleanup_on_sigterm()


def retry_callable(
    callable_,
    ex_type: type = Exception,
    wait_interval=1,
    max_retries=-1,
    sync: bool = None,
):
    if inspect.iscoroutinefunction(callable_) or sync is False:

        @functools.wraps(callable)
        async def retry_call(*args, **kwargs):
            num_retried = 0
            while max_retries < 0 or num_retried < max_retries:
                num_retried += 1
                try:
                    return await callable_(*args, **kwargs)
                except ex_type:
                    await asyncio.sleep(wait_interval)

    else:

        @functools.wraps(callable)
        def retry_call(*args, **kwargs):
            num_retried = 0
            ex = None
            while max_retries < 0 or num_retried < max_retries:
                num_retried += 1
                try:
                    return callable_(*args, **kwargs)
                except ex_type as e:
                    ex = e
                    time.sleep(wait_interval)
            assert ex is not None
            raise ex  # pylint: disable-msg=E0702

    return retry_call