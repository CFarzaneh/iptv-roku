import React from 'react';
import { resolutionLabel } from './telemetry.mjs';
import badge720p from './assets/quality/720p.svg';
import badge1080p from './assets/quality/1080p.svg';
import badge2k from './assets/quality/2k.svg';
import badge4k from './assets/quality/4k.svg';

const badges = { '720p': badge720p, '1080p': badge1080p, '2K': badge2k, '4K': badge4k };

export function ResolutionBadge({ width, height }) {
  const label = resolutionLabel(width, height);
  return badges[label]
    ? <img className="quality-badge" src={badges[label]} alt={`${label} video quality`} title={`${width} × ${height}`} height="28"/>
    : label;
}
