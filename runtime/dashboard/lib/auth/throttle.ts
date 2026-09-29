export class Throttle {
  private failures = 0;
  private lockedUntil = 0;

  constructor(
    private readonly maxFailures = 5,
    private readonly lockMs = 30_000,
  ) {}

  blocked(now: number = Date.now()): boolean {
    return now < this.lockedUntil;
  }

  fail(now: number = Date.now()): void {
    this.failures += 1;
    if (this.failures >= this.maxFailures) {
      this.lockedUntil = now + this.lockMs;
      this.failures = 0;
    }
  }

  succeed(): void {
    this.failures = 0;
    this.lockedUntil = 0;
  }
}

// One process serves the dashboard, so an in-memory counter is the whole throttle.
// Tests reset it with loginThrottle.succeed().
export const loginThrottle = new Throttle();
