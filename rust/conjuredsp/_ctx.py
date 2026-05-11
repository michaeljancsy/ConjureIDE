"""Internal: read-only views over ctx attributes.

The `ParamsView` class wraps the parameters dict that Rust mutates in place
each block and exposes it to scripts as `ctx.params`. It supports both
dict-style (`ctx.params["name"]`) and attribute-style (`ctx.params.name`)
access; writes raise with the list of declared param names so typos
surface clearly.

Per-block read-through (not snapshot): `ParamsView` holds a reference to
the underlying dict, so Rust's in-place per-block update is visible to
the script without us rebuilding the proxy each callback.

Authors should not import from this module directly — it's an
implementation detail of the ctx object. The public surface for working
with params is `ctx.params` itself.
"""


class ParamsView:
    """Read-only view of ctx.params. Supports dict-style and attribute-style access."""

    __slots__ = ("_d",)

    def __init__(self, d):
        # Use object.__setattr__ to bypass our own __setattr__ guard during init.
        object.__setattr__(self, "_d", d)

    # Dict-style read with helpful "did you mean" error.
    def __getitem__(self, k):
        try:
            return self._d[k]
        except KeyError:
            raise KeyError(f"no param {k!r}; declared: {sorted(self._d)}")

    # Attribute-style read mirrors the helpful error so typos in either
    # access style produce the same surface.
    def __getattr__(self, k):
        try:
            return self._d[k]
        except KeyError:
            raise AttributeError(f"no param {k!r}; declared: {sorted(self._d)}")

    def __setattr__(self, k, v):
        raise AttributeError("ctx.params is read-only")

    def __setitem__(self, k, v):
        raise TypeError("ctx.params is read-only")

    def __contains__(self, k):
        return k in self._d

    def __iter__(self):
        return iter(self._d)

    def __len__(self):
        return len(self._d)

    def keys(self):
        return self._d.keys()

    def values(self):
        return self._d.values()

    def items(self):
        return self._d.items()

    def get(self, k, default=None):
        return self._d.get(k, default)

    def __repr__(self):
        return f"ParamsView({dict(self._d)!r})"
