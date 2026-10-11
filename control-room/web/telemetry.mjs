export function resolutionLabel(width, height) {
  if (!Number.isInteger(width) || !Number.isInteger(height) || width <= 0 || height <= 0 || width > 16384 || height > 16384) return '—';
  // 2K here is the common dashboard label for 1440-line (QHD) streams.
  if (height === 2160 && (width === 3840 || width === 4096)) return '4K';
  if (height === 1440) return '2K';
  if (height === 1080) return '1080p';
  if (height === 720) return '720p';
  return `${height}p`;
}

export function rokuOSLabel(version) {
  // Older installed builds used the deprecated API and sent this placeholder.
  if (!version || /^999\.99E99999A$/i.test(version)) return '—';
  return version;
}
