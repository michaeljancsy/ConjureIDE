"""Type definitions for ConjureDSP preset development.

Provides type aliases and TypedDicts for autocomplete and type checking.
"""

from typing import TypedDict, Literal

import numpy as np
import numpy.typing as npt

# Audio buffer type — what process() receives and writes to
AudioBuffer = npt.NDArray[np.float32]

# Channel list type — list of audio buffers, one per channel
ChannelList = list[AudioBuffer]


class ParamSpec(TypedDict, total=False):
    """Specification for a single parameter in the PARAMS dict.

    Required fields: min, max
    Optional fields: unit, default, curve
    """

    min: float
    max: float
    unit: str
    default: float
    curve: Literal["linear", "log"]


# Type alias for the full PARAMS dict
ParamDict = dict[str, ParamSpec]

# Type alias for the params argument in process() when PARAMS is defined
ParamValues = dict[str, float]
