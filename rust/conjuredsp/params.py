"""Parameter metadata helpers for ConjureDSP presets.

Shorthand builders for PARAMS dict entries. These produce ParamSpec dicts
with sensible defaults for common parameter types.
"""

from .types import ParamSpec


def param(
    min: float,
    max: float,
    *,
    unit: str = "",
    default: float | None = None,
    curve: str = "linear",
) -> ParamSpec:
    """Build a PARAMS entry with explicit min/max.

    Args:
        min: Minimum value.
        max: Maximum value.
        unit: Display unit (e.g., "Hz", "dB", "ms").
        default: Initial value. Defaults to min if not specified.
        curve: "linear" (default) or "log" for exponential mapping.

    Returns:
        A ParamSpec dict suitable for use in PARAMS.

    Raises:
        ValueError: if `default` is outside `[min, max]`. The named builders
            (`mix`, `pct`, `toggle`, `ratio`) bake in their range and route
            through here, so a `mix(default=100.0)` (mistakenly using the
            0..100 percentage convention) raises immediately at script-load
            time instead of silently clamping to 1.0.
    """
    if default is not None and not (min <= default <= max):
        raise ValueError(
            f"param() default {default} is outside the declared range "
            f"[{min}, {max}]. Did you mix up mix() (0..1) with pct() (0..100)?"
        )
    spec: ParamSpec = {"min": min, "max": max, "unit": unit, "curve": curve}  # type: ignore[typeddict-item]
    if default is not None:
        spec["default"] = default
    else:
        spec["default"] = min
    return spec


def freq(
    min: float = 20.0, max: float = 20000.0, default: float = 1000.0
) -> ParamSpec:
    """Frequency parameter with Hz unit and log curve.

    Default range: 20 Hz to 20 kHz (audible spectrum).
    """
    return param(min, max, unit="Hz", default=default, curve="log")


def db(min: float = -60.0, max: float = 12.0, default: float = 0.0) -> ParamSpec:
    """Decibel parameter with dB unit and linear curve."""
    return param(min, max, unit="dB", default=default)


def time_ms(
    min: float = 0.1, max: float = 1000.0, default: float = 100.0
) -> ParamSpec:
    """Time parameter in milliseconds with log curve.

    Log curve gives fine control at short times (attack) and coarse
    control at long times (release).
    """
    return param(min, max, unit="ms", default=default, curve="log")


def pct(default: float = 50.0) -> ParamSpec:
    """Percentage parameter, 0-100 with % unit."""
    return param(0.0, 100.0, unit="%", default=default)


def mix(default: float = 0.5) -> ParamSpec:
    """Wet/dry mix parameter, 0.0 (dry) to 1.0 (wet)."""
    return param(0.0, 1.0, default=default)


def toggle(default: float = 0.0) -> ParamSpec:
    """On/off toggle parameter (0 or 1)."""
    spec = param(0.0, 1.0, default=default)
    spec["style"] = "toggle"
    return spec


def choice(*labels: str, default: str | None = None) -> ParamSpec:
    """Enum parameter rendered as a dropdown menu.

    Args:
        *labels: Option labels (e.g., "Low", "Mid", "High").
        default: Default option label. Defaults to the first label.

    Returns:
        A ParamSpec dict. The script receives the selected index as a float
        (e.g., 0.0, 1.0, 2.0).
    """
    if len(labels) < 2:
        raise ValueError("choice() requires at least 2 labels")
    default_idx = 0.0
    if default is not None:
        try:
            default_idx = float(labels.index(default))
        except ValueError:
            raise ValueError(f"default {default!r} not in labels: {labels}")
    spec = param(0.0, float(len(labels) - 1), default=default_idx)
    spec["style"] = "choice"
    spec["options"] = list(labels)
    return spec


def ratio(min: float = 1.0, max: float = 20.0, default: float = 4.0) -> ParamSpec:
    """Compression/expansion ratio parameter."""
    return param(min, max, unit=":1", default=default)


def integer(
    min: int,
    max: int,
    *,
    unit: str = "",
    default: int | None = None,
) -> ParamSpec:
    """Integer-valued parameter.

    Renders as a slider/knob in the in-plugin UI and as a discrete-stepped
    parameter (`AudioUnitParameterUnit.indexed`) in DAWs, so automation lanes
    snap to whole numbers. The script receives an exact integer-valued float
    (e.g. ``4.0``).

    Args:
        min: Minimum integer value (inclusive).
        max: Maximum integer value (inclusive).
        unit: Display unit (e.g., ``"bits"``, ``"x"``). Empty string for none.
        default: Initial value. Defaults to ``min`` if not specified.

    Returns:
        A ParamSpec dict with ``style="integer"`` and a linear curve.
    """
    # `param()` validates default \u2208 [min, max] and raises ValueError otherwise.
    spec = param(float(min), float(max), unit=unit, default=float(default if default is not None else min))
    spec["style"] = "integer"
    return spec
