"""The Whisplay button's factory-reset gesture (ADR-0013).

Hold 10 s (countdown drawn from 3 s), release, then press again within 5 s.
Physical access is the authorization; the confirm press is what keeps a
bumped or stuck button from wiping the unit. Pure and stdlib-only: the caller
feeds timestamped press/release events and reads one Intent per tick.
"""
import dataclasses
import math
from typing import Optional, Tuple

HOLD_S = 10.0
COUNTDOWN_FROM_S = 3.0
CONFIRM_S = 5.0
RED = (255, 0, 0)

IDLE, HOLDING, ARMED, TRIGGERED = "idle", "holding", "armed", "triggered"

TEXT_ARMED = "Release, then press to confirm"
TEXT_CONFIRM = "Press again to reset"
TEXT_RESETTING = "Resetting"


@dataclasses.dataclass(frozen=True)
class Intent:
    overlay_text: Optional[str] = None
    countdown: Optional[int] = None
    led: Optional[Tuple[int, int, int]] = None
    trigger: bool = False


class ResetGesture:
    def __init__(self):
        self.state = IDLE
        self._pressed_at = 0.0
        self._released_at = None
        self._fire = False

    def _expire(self, now):
        if self.state == ARMED and self._released_at is not None \
                and now - self._released_at > CONFIRM_S:
            self.state = IDLE

    def press(self, now):
        self._expire(now)
        if self.state == IDLE:
            self.state, self._pressed_at = HOLDING, now
        elif self.state == ARMED and self._released_at is not None:
            self.state, self._fire = TRIGGERED, True

    def release(self, now):
        self._expire(now)
        if self.state == HOLDING:
            # A release can reach us before the tick that would have armed.
            if now - self._pressed_at >= HOLD_S:
                self.state, self._released_at = ARMED, now
            else:
                self.state = IDLE
        elif self.state == ARMED and self._released_at is None:
            self._released_at = now

    def tick(self, now):
        self._expire(now)
        if self.state == HOLDING and now - self._pressed_at >= HOLD_S:
            self.state, self._released_at = ARMED, None
        if self.state == HOLDING:
            held = now - self._pressed_at
            if held < COUNTDOWN_FROM_S:
                return Intent()
            n = math.ceil(HOLD_S - held)
            return Intent(f"Factory reset in {n}\nRelease to cancel", countdown=n)
        if self.state == ARMED:
            text = TEXT_ARMED if self._released_at is None else TEXT_CONFIRM
            return Intent(text, led=RED)
        if self.state == TRIGGERED:
            fire, self._fire = self._fire, False
            return Intent(TEXT_RESETTING, led=RED, trigger=fire)
        return Intent()
