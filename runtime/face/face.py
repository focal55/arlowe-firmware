#!/usr/bin/env python3
"""
Arlowe Face Display
Animated face for Whisplay 240x280 LCD
"""
import sys
import math
import time
import random
import signal
from dataclasses import dataclass
from enum import Enum
from typing import Optional, Tuple

# WhisPlay vendor SDK lookup — see third_party/whisplay-driver/PROVENANCE.md
# At runtime, the driver is expected at /opt/arlowe/third_party/whisplay-driver/.
# Override for dev environments that have the driver installed at a non-standard path.
import os
_WHISPLAY_DRIVER_PATH = os.environ.get(
    "ARLOWE_WHISPLAY_DRIVER_PATH",
    "/opt/arlowe/third_party/whisplay-driver",
)
if _WHISPLAY_DRIVER_PATH not in sys.path:
    sys.path.insert(0, _WHISPLAY_DRIVER_PATH)
from WhisPlay import WhisPlayBoard
from PIL import Image, ImageDraw, ImageFilter

# Display physical dimensions
DISP_WIDTH, DISP_HEIGHT = 240, 280
# Drawing canvas (rotated - we draw landscape, then rotate to portrait)
WIDTH, HEIGHT = 280, 240

class State(Enum):
    IDLE = "idle"
    THINKING = "thinking"
    TALKING = "talking"
    LISTENING = "listening"
    SLEEPING = "sleeping"
    # New expressions
    HAPPY = "happy"
    SURPRISED = "surprised"
    CONFUSED = "confused"
    SAD = "sad"
    EXCITED = "excited"

@dataclass
class FaceState:
    state: State = State.IDLE
    blink_progress: float = 0.0  # 0=open, 1=closed
    eye_offset_x: float = 0.0
    eye_offset_y: float = 0.0
    mouth_open: float = 0.0  # 0=smile, 1=open
    breath_phase: float = 0.0
    glow_intensity: float = 1.0
    # Expression params
    eyebrow_raise: float = 0.0  # -1=frown, 0=neutral, 1=raised
    eyebrow_asymmetry: float = 0.0  # 0=symmetric, positive=right higher
    eye_scale: float = 1.0  # for surprised look
    eye_squint: float = 0.0  # 0=normal, 1=fully squinted
    mouth_curve: float = 0.5  # 0=frown, 0.5=neutral, 1=big smile
    mouth_width: float = 1.0  # 0.5=narrow, 1=normal, 1.5=wide

class ArloweeFace:
    """Animated face renderer for Whisplay"""

    # Colors
    BG_COLOR = (17, 17, 17)
    PRIMARY = (80, 180, 255)  # Soft neon blue

    # Background colors for different modes
    BG_COLORS = {
        "default": (17, 17, 17),       # Near black
        "wake": (60, 20, 40),          # Soft neon pink
        "error": (40, 10, 10),         # Dark red
        "excited": (20, 50, 30),       # Soft green
        "talking": (20, 40, 60),       # Soft neon blue
    }

    _bg_mode = "default"
    _source = None  # "cloud", "local", or None

    # Corner padding for rounded display
    CORNER_PADDING = 15

    # Face geometry
    EYE_Y = 100  # Y position of eyes
    EYE_SPACING = 80  # Distance between eye centers
    EYE_RADIUS = 25
    NOSE_Y = 150
    NOSE_RADIUS = 7
    MOUTH_Y = 190
    MOUTH_WIDTH = 50

    def __init__(self):
        self.board = WhisPlayBoard()
        self.board.set_backlight(100)
        self.state = FaceState()
        self.running = True
        self.last_blink = time.time()
        self.next_blink = random.uniform(2, 5)
        self.last_look = time.time()
        self.target_look = (0, 0)

        # Target values for smooth transitions
        self.target_eyebrow = 0.0
        self.target_eyebrow_asymmetry = 0.0
        self.target_eye_scale = 1.0
        self.target_eye_squint = 0.0
        self.target_mouth_curve = 0.5
        self.target_mouth_width = 1.0

        # Idle behaviors
        self._idle_behavior = None  # None, "whistling", "dozing", "panic_wake"
        self._idle_behavior_start = 0
        self._next_idle_behavior = time.time() + random.uniform(15, 30)
        self._whistle_phase = 0.0

        # Set up signal handlers
        signal.signal(signal.SIGTERM, self._handle_signal)
        signal.signal(signal.SIGINT, self._handle_signal)

    def _handle_signal(self, signum, frame):
        self.running = False

    def _ease_in_out(self, t: float) -> float:
        """Smooth easing function"""
        return t * t * (3 - 2 * t)

    def _draw_glow_circle(self, draw: ImageDraw, cx: int, cy: int, radius: int,
                          color: Tuple[int, int, int], glow: float = 1.0):
        """Draw a circle with glow effect"""
        r, g, b = color
        r = int(r * glow)
        g = int(g * glow)
        b = int(b * glow)

        draw.ellipse(
            [cx - radius, cy - radius, cx + radius, cy + radius],
            fill=(r, g, b)
        )

    def _draw_eyebrow(self, draw: ImageDraw, cx: int, cy: int, raise_amount: float,
                      glow: float, is_left: bool, asymmetry: float = 0.0):
        """Draw eyebrow line above eye"""
        color = tuple(int(c * glow) for c in self.PRIMARY)
        width = 30

        # Apply asymmetry: positive = right eyebrow higher
        if is_left:
            raise_amount = raise_amount - asymmetry * 0.5
        else:
            raise_amount = raise_amount + asymmetry * 0.5

        # Vertical offset - moved much higher above eyes (-35 base instead of -15)
        y_offset = int(-35 - raise_amount * 15)

        # Angle for expression
        if raise_amount > 0.3:  # Raised/surprised
            angle = 0
        elif raise_amount < -0.3:  # Frown/angry
            angle = 15 if is_left else -15
        else:
            angle = 5 if is_left else -5

        import math as m
        rad = m.radians(angle)
        half_width = width // 2

        x1 = cx - half_width
        x2 = cx + half_width
        y1 = cy + y_offset + int(m.sin(rad) * half_width)
        y2 = cy + y_offset - int(m.sin(rad) * half_width)

        draw.line([x1, y1, x2, y2], fill=color, width=4)

    def _draw_star_eye(self, draw: ImageDraw, cx: int, cy: int, glow: float, size: int = 25):
        """Draw a star-shaped eye for excited state"""
        color = tuple(int(c * glow) for c in self.PRIMARY)

        # 4-point star
        draw.line([cx - size, cy, cx + size, cy], fill=color, width=4)
        draw.line([cx, cy - size, cx, cy + size], fill=color, width=4)

        # Diagonal lines (smaller)
        diag = int(size * 0.7)
        draw.line([cx - diag, cy - diag, cx + diag, cy + diag], fill=color, width=3)
        draw.line([cx - diag, cy + diag, cx + diag, cy - diag], fill=color, width=3)

    def _draw_eye(self, draw: ImageDraw, cx: int, cy: int, blink: float,
                  offset_x: float, offset_y: float, glow: float, scale: float = 1.0,
                  squint: float = 0.0, star_eyes: bool = False):
        """Draw a single eye with blink and squint animation"""
        cx = int(cx + offset_x)
        cy = int(cy + offset_y)

        radius = int(self.EYE_RADIUS * scale)

        if star_eyes:
            self._draw_star_eye(draw, cx, cy, glow, radius)
            return

        # Combine blink and squint for vertical squish
        total_squish = max(blink, squint * 0.6)

        if total_squish > 0.9:
            # Eye closed - draw line
            draw.line(
                [cx - radius, cy, cx + radius, cy],
                fill=self.PRIMARY, width=4
            )
        elif total_squish > 0:
            # Partially closed/squinted - squished ellipse
            squish_factor = 1 - total_squish * 0.9
            draw.ellipse(
                [cx - radius, cy - int(radius * squish_factor),
                 cx + radius, cy + int(radius * squish_factor)],
                fill=tuple(int(c * glow) for c in self.PRIMARY)
            )
        else:
            # Eye fully open
            self._draw_glow_circle(draw, cx, cy, radius, self.PRIMARY, glow)

    def _draw_mouth(self, draw: ImageDraw, state: State, open_amount: float,
                    curve: float, glow: float, width_mult: float = 1.0):
        """Draw mouth based on state and expression"""
        cx = WIDTH // 2
        cy = self.MOUTH_Y

        color = tuple(int(c * glow) for c in self.PRIMARY)
        mouth_w = int(self.MOUTH_WIDTH * width_mult)

        if self._idle_behavior == "whistling" and state == State.IDLE:
            # Whistling mouth — small O that pulses
            whistle_size = 6 + 3 * abs(math.sin(self._whistle_phase * 4))
            draw.ellipse(
                [cx - whistle_size, cy - whistle_size, cx + whistle_size, cy + whistle_size],
                outline=color, width=3
            )
            return
        elif state == State.SLEEPING:
            draw.line([cx - 20, cy, cx + 20, cy], fill=color, width=3)
        elif state == State.THINKING:
            # Short straight line, slightly pursed
            draw.line([cx - int(25 * width_mult), cy, cx + int(25 * width_mult), cy], fill=color, width=3)
        elif state == State.TALKING and open_amount > 0.1:
            # Open mouth when talking - oval that changes size
            height = int(15 * open_amount)
            width = int(20 + 10 * (1 - open_amount))  # Wider when less open
            draw.ellipse(
                [cx - width, cy - height, cx + width, cy + height],
                outline=color, width=3
            )
        elif state == State.SURPRISED:
            # Small O mouth for surprise
            draw.ellipse(
                [cx - 15, cy - 15, cx + 15, cy + 15],
                outline=color, width=3
            )
        elif state == State.SAD or curve < 0.3:
            # Frown curve
            draw.arc(
                [cx - self.MOUTH_WIDTH, cy - 10, cx + self.MOUTH_WIDTH, cy + 40],
                start=180, end=360,
                fill=color, width=3
            )
        elif state == State.HAPPY or state == State.EXCITED or curve > 0.7:
            # Big smile
            draw.arc(
                [cx - self.MOUTH_WIDTH - 10, cy - 30, cx + self.MOUTH_WIDTH + 10, cy + 25],
                start=0, end=180,
                fill=color, width=4
            )
        else:
            # Normal smile curve
            draw.arc(
                [cx - self.MOUTH_WIDTH, cy - 20, cx + self.MOUTH_WIDTH, cy + 30],
                start=0, end=180,
                fill=color, width=3
            )

    def _draw_sweat_drop(self, draw: ImageDraw, glow: float):
        """Draw sweat drop for confused state"""
        color = tuple(int(c * glow * 0.6) for c in self.PRIMARY)
        cx, cy = WIDTH - 50, 90
        draw.polygon([
            (cx, cy - 10),
            (cx - 8, cy + 5),
            (cx + 8, cy + 5)
        ], fill=color)
        draw.ellipse([cx - 8, cy, cx + 8, cy + 12], fill=color)

    def _draw_source_icon(self, draw: ImageDraw, glow: float):
        """Draw cloud or home icon in upper right corner"""
        if self._source is None:
            return

        icon_x = WIDTH - self.CORNER_PADDING - 20
        icon_y = self.CORNER_PADDING + 10

        color = tuple(int(c * glow * 0.8) for c in self.PRIMARY)

        if self._source == "cloud":
            # Draw simple cloud shape
            draw.ellipse([icon_x - 15, icon_y - 5, icon_x + 5, icon_y + 12], fill=color)
            draw.ellipse([icon_x - 5, icon_y - 10, icon_x + 15, icon_y + 8], fill=color)
            draw.ellipse([icon_x + 5, icon_y - 5, icon_x + 20, icon_y + 12], fill=color)
            draw.rectangle([icon_x - 12, icon_y + 2, icon_x + 17, icon_y + 10], fill=color)

        elif self._source == "local":
            # Draw simple house shape
            draw.polygon([
                (icon_x, icon_y - 10),      # Top
                (icon_x - 15, icon_y + 2),  # Bottom left
                (icon_x + 15, icon_y + 2),  # Bottom right
            ], fill=color)
            draw.rectangle([icon_x - 10, icon_y + 2, icon_x + 10, icon_y + 15], fill=color)
            # Door
            bg = self.BG_COLORS.get(self._bg_mode, self.BG_COLOR)
            draw.rectangle([icon_x - 3, icon_y + 7, icon_x + 3, icon_y + 15], fill=bg)

    def _draw_sparkles(self, draw: ImageDraw, phase: float, glow: float):
        """Draw sparkles for excited state"""
        color = tuple(int(c * glow) for c in self.PRIMARY)

        sparkle_positions = [
            (25, 40),    # Top left
            (215, 40),   # Top right
            (15, 140),   # Mid left
            (225, 140),  # Mid right
            (25, 240),   # Bottom left
            (215, 240),  # Bottom right
        ]

        for i, (sx, sy) in enumerate(sparkle_positions):
            size = 6 + 4 * abs(math.sin(phase + i * math.pi / 3))

            draw.line([sx - size, sy, sx + size, sy], fill=color, width=2)
            draw.line([sx, sy - size, sx, sy + size], fill=color, width=2)

            diag = int(size * 0.6)
            draw.line([sx - diag, sy - diag, sx + diag, sy + diag], fill=color, width=1)
            draw.line([sx - diag, sy + diag, sx + diag, sy - diag], fill=color, width=1)

    def render_frame(self) -> bytes:
        """Render a single frame and return RGB565 pixel data"""
        bg = self.BG_COLORS.get(self._bg_mode, self.BG_COLOR)
        img = Image.new('RGB', (WIDTH, HEIGHT), bg)
        draw = ImageDraw.Draw(img)

        s = self.state

        # Apply breathing to glow
        breath_mod = 0.95 + 0.05 * math.sin(s.breath_phase)
        glow = s.glow_intensity * breath_mod

        if s.state == State.CONFUSED:
            self._draw_sweat_drop(draw, glow)
        elif s.state == State.EXCITED:
            self._draw_sparkles(draw, s.breath_phase * 3, glow)

        left_eye_x = WIDTH // 2 - self.EYE_SPACING // 2
        right_eye_x = WIDTH // 2 + self.EYE_SPACING // 2

        if abs(s.eyebrow_raise) > 0.1 or abs(s.eyebrow_asymmetry) > 0.1:
            brow_offset_x = s.eye_offset_x * 0.5
            brow_offset_y = s.eye_offset_y * 0.3
            self._draw_eyebrow(draw, int(left_eye_x + brow_offset_x), int(self.EYE_Y + brow_offset_y),
                              s.eyebrow_raise, glow, True, s.eyebrow_asymmetry)
            self._draw_eyebrow(draw, int(right_eye_x + brow_offset_x), int(self.EYE_Y + brow_offset_y),
                              s.eyebrow_raise, glow, False, s.eyebrow_asymmetry)

        star_eyes = (s.state == State.EXCITED)
        self._draw_eye(draw, left_eye_x, self.EYE_Y, s.blink_progress,
                       s.eye_offset_x, s.eye_offset_y, glow, s.eye_scale, s.eye_squint, star_eyes)
        self._draw_eye(draw, right_eye_x, self.EYE_Y, s.blink_progress,
                       s.eye_offset_x, s.eye_offset_y, glow, s.eye_scale, s.eye_squint, star_eyes)

        self._draw_glow_circle(draw, WIDTH // 2, self.NOSE_Y, self.NOSE_RADIUS,
                               self.PRIMARY, glow * 0.7)

        self._draw_mouth(draw, s.state, s.mouth_open, s.mouth_curve, glow, s.mouth_width)

        self._draw_source_icon(draw, glow)

        # Rotate 90 degrees counter-clockwise to fit display
        # Canvas is 280x240, after CCW rotation becomes 240x280 (matches display)
        img = img.rotate(90, expand=True)

        # Convert to RGB565 for display (now 240x280)
        pixels = []
        for y in range(DISP_HEIGHT):  # 280
            for x in range(DISP_WIDTH):  # 240
                r, g, b = img.getpixel((x, y))
                rgb565 = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
                pixels.extend([(rgb565 >> 8) & 0xFF, rgb565 & 0xFF])

        return bytes(pixels)

    def update_animation(self, dt: float):
        """Update animation state"""
        s = self.state
        now = time.time()

        # Breathing animation (faster for excited)
        breath_speed = 1.5 if s.state == State.EXCITED else 0.8
        s.breath_phase += dt * breath_speed
        if s.breath_phase > 2 * math.pi:
            s.breath_phase -= 2 * math.pi

        # Blinking (more frequent when excited, less when sad)
        if s.state != State.SLEEPING:
            blink_interval = self.next_blink
            if s.state == State.EXCITED:
                blink_interval *= 0.5
            elif s.state == State.SAD:
                blink_interval *= 1.5

            if now - self.last_blink > blink_interval:
                self.last_blink = now
                self.next_blink = random.uniform(2, 5)

            blink_time = now - self.last_blink
            if blink_time < 0.15:
                s.blink_progress = self._ease_in_out(blink_time / 0.15)
            elif blink_time < 0.3:
                s.blink_progress = self._ease_in_out(1 - (blink_time - 0.15) / 0.15)
            else:
                s.blink_progress = 0
        else:
            s.blink_progress = 1.0  # Eyes closed when sleeping

        # Eye movement (idle/thinking)
        if s.state == State.THINKING:
            # Look up and to the right
            self.target_look = (8, -6)
            s.eye_offset_x += (self.target_look[0] - s.eye_offset_x) * dt * 3
            s.eye_offset_y += (self.target_look[1] - s.eye_offset_y) * dt * 3
        elif s.state in (State.IDLE, State.CONFUSED):
            if now - self.last_look > 2:
                self.target_look = (
                    random.uniform(-10, 10),
                    random.uniform(-5, 5)
                )
                self.last_look = now

            s.eye_offset_x += (self.target_look[0] - s.eye_offset_x) * dt * 2
            s.eye_offset_y += (self.target_look[1] - s.eye_offset_y) * dt * 2
        elif s.state == State.LISTENING:
            s.eye_offset_x += (0 - s.eye_offset_x) * dt * 3
            s.eye_offset_y += (0 - s.eye_offset_y) * dt * 3

        # Talking animation
        if s.state == State.TALKING:
            s.mouth_open = 0.3 + 0.7 * abs(math.sin(now * 8))
        else:
            s.mouth_open = max(0, s.mouth_open - dt * 5)

        # Idle behavior system (whistling, dozing off)
        if s.state == State.IDLE:
            if self._idle_behavior is None and now > self._next_idle_behavior:
                behavior = random.choice(["whistling", "whistling", "dozing"])
                self._idle_behavior = behavior
                self._idle_behavior_start = now
                print(f"  [idle] {behavior}", flush=True)

            if self._idle_behavior == "whistling":
                self._whistle_phase += dt
                elapsed = now - self._idle_behavior_start
                self.target_look = (3, -4)
                if elapsed > 4:
                    self._idle_behavior = None
                    self._next_idle_behavior = now + random.uniform(20, 45)
                    self._whistle_phase = 0

            elif self._idle_behavior == "dozing":
                elapsed = now - self._idle_behavior_start
                if elapsed < 3:
                    s.blink_progress = min(1.0, elapsed / 2.5)
                    s.glow_intensity = max(0.4, 1.0 - elapsed / 3.5)
                elif elapsed < 3.5:
                    s.blink_progress = 1.0
                    s.glow_intensity = 0.4
                elif elapsed < 4.0:
                    # PANIC WAKE - eyes go wide
                    s.blink_progress = 0
                    s.eye_scale += (1.4 - s.eye_scale) * dt * 15
                    s.glow_intensity += (1.3 - s.glow_intensity) * dt * 10
                    self.target_eyebrow = 0.9
                    self.target_mouth_curve = 0.3
                elif elapsed < 5.5:
                    self.target_look = (random.uniform(-15, 15), random.uniform(-8, 8))
                    s.eye_scale += (1.2 - s.eye_scale) * dt * 5
                else:
                    self._idle_behavior = None
                    self._next_idle_behavior = now + random.uniform(30, 60)
                    self.target_eyebrow = 0.2
                    self.target_eye_scale = 1.0
                    self.target_mouth_curve = 0.5
        else:
            if self._idle_behavior is not None:
                self._idle_behavior = None
                self._whistle_phase = 0

        # Smooth transitions for expression params
        s.eyebrow_raise += (self.target_eyebrow - s.eyebrow_raise) * dt * 5
        s.eyebrow_asymmetry += (self.target_eyebrow_asymmetry - s.eyebrow_asymmetry) * dt * 5
        s.eye_scale += (self.target_eye_scale - s.eye_scale) * dt * 5
        s.eye_squint += (self.target_eye_squint - s.eye_squint) * dt * 5
        s.mouth_curve += (self.target_mouth_curve - s.mouth_curve) * dt * 5
        s.mouth_width += (self.target_mouth_width - s.mouth_width) * dt * 5

        glow_targets = {
            State.SLEEPING: 0.4,
            State.LISTENING: 1.2,
            State.HAPPY: 1.1,
            State.EXCITED: 1.3,
            State.SAD: 0.7,
            State.SURPRISED: 1.15,
        }
        target_glow = glow_targets.get(s.state, 1.0)
        s.glow_intensity += (target_glow - s.glow_intensity) * dt * 3

    def set_bg_mode(self, mode: str):
        """Set background color mode: default, wake, error"""
        if mode in self.BG_COLORS:
            self._bg_mode = mode

    def set_source(self, source: str):
        """Set source indicator: 'cloud', 'local', or None/empty to clear"""
        if source in ('cloud', 'local'):
            self._source = source
        else:
            self._source = None

    def set_state(self, state: State):
        """Change face state"""
        self.state.state = state

        # Format: (eyebrow_raise, eyebrow_asymmetry, eye_scale, eye_squint, mouth_curve, mouth_width)
        expression_params = {
            State.IDLE: (0.2, 0.0, 1.0, 0.0, 0.5, 1.0),
            State.THINKING: (0.4, 1.0, 1.0, 0.5, 0.35, 0.6),
            State.TALKING: (0.2, 0.0, 1.0, 0.0, 0.5, 1.0),
            State.LISTENING: (0.3, 0.0, 1.0, 0.0, 0.5, 1.0),
            State.SLEEPING: (0.0, 0.0, 1.0, 0.0, 0.3, 0.8),
            State.HAPPY: (0.3, 0.0, 1.0, 0.0, 0.9, 1.2),
            State.SURPRISED: (0.8, 0.0, 1.3, 0.0, 0.5, 1.0),
            State.CONFUSED: (-0.2, 0.5, 1.0, 0.3, 0.4, 0.8),
            State.SAD: (-0.5, 0.0, 0.9, 0.0, 0.15, 0.8),
            State.EXCITED: (0.5, 0.0, 1.1, 0.0, 1.0, 1.3),
        }

        params = expression_params.get(state, (0.0, 0.0, 1.0, 0.0, 0.5, 1.0))
        self.target_eyebrow = params[0]
        self.target_eyebrow_asymmetry = params[1]
        self.target_eye_scale = params[2]
        self.target_eye_squint = params[3]
        self.target_mouth_curve = params[4]
        self.target_mouth_width = params[5]

        colors = {
            State.IDLE: (80, 180, 255),
            State.THINKING: (150, 100, 255),
            State.TALKING: (80, 180, 255),
            State.LISTENING: (100, 220, 255),
            State.SLEEPING: (30, 50, 80),
            State.HAPPY: (100, 255, 150),
            State.SURPRISED: (255, 200, 100),
            State.CONFUSED: (180, 150, 255),
            State.SAD: (80, 100, 180),
            State.EXCITED: (255, 150, 200),
        }
        r, g, b = colors.get(state, (80, 180, 255))
        self.board.set_rgb(r, g, b)

    def run(self, fps: int = 20):
        """Main animation loop"""
        frame_time = 1.0 / fps
        last_frame = time.time()

        print(f"Arlowe face starting (FPS: {fps})")
        self.set_state(State.IDLE)

        try:
            while self.running:
                now = time.time()
                dt = now - last_frame

                if dt >= frame_time:
                    self.update_animation(dt)
                    pixels = self.render_frame()
                    self.board.draw_image(0, 0, DISP_WIDTH, DISP_HEIGHT, list(pixels))
                    last_frame = now
                else:
                    time.sleep(frame_time - dt)

        except KeyboardInterrupt:
            pass
        finally:
            self.cleanup()

    def cleanup(self):
        """Clean up resources"""
        print("Shutting down face...")
        self.state.glow_intensity = 0
        pixels = self.render_frame()
        self.board.draw_image(0, 0, DISP_WIDTH, DISP_HEIGHT, list(pixels))
        self.board.set_rgb(0, 0, 0)
        self.board.set_backlight(0)
        self.board.cleanup()


def main():
    face = ArloweeFace()

    import threading

    def state_cycle():
        states = [State.IDLE, State.THINKING, State.LISTENING, State.TALKING,
                  State.HAPPY, State.SURPRISED, State.CONFUSED, State.SAD,
                  State.EXCITED, State.SLEEPING]
        idx = 0
        while face.running:
            time.sleep(5)
            idx = (idx + 1) % len(states)
            face.set_state(states[idx])
            print(f"State: {states[idx].value}")

    t = threading.Thread(target=state_cycle, daemon=True)
    t.start()

    face.run()


if __name__ == "__main__":
    main()
