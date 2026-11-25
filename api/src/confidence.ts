// Turning the hop-by-hop quality counts into one word a person can act on.
//
// The ETA endpoint and the new arrivals endpoint both need this, so it
// lives in one place. The wording is deliberately plain: it is shown to a
// commuter as-is, not just read by a developer.

import type { HopSource } from './eta.ts';

export interface Confidence {
  level: 'high' | 'medium' | 'low';
  because: string;
}

export function describeConfidence(
  quality: Record<HopSource, number>,
  hops: number,
): Confidence {
  // A journey with no hops (the bus is already at the stop) is not a
  // prediction at all. Say that rather than dividing by zero.
  if (hops <= 0) {
    return {
      level: 'high',
      because: 'The bus is already at this stop.',
    };
  }

  const best = quality['this-hour-this-daytype'];
  const coarse = quality['any-day-any-hour'];

  if (best / hops >= 0.8) {
    return {
      level: 'high',
      because: 'Nearly every leg was estimated from buses on this same route, ' +
        'at this hour, on this kind of day.',
    };
  }
  if (coarse / hops >= 0.5) {
    return {
      level: 'low',
      because: 'Most legs had too little matching history, so they fall back to ' +
        'an all-day average. Treat the timing as rough.',
    };
  }
  return {
    level: 'medium',
    because: 'Some legs had too little history for this exact hour and fall back ' +
      'to a broader average.',
  };
}
