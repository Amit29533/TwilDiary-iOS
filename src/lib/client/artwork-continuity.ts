type WarmImage = { src: string; decoding: 'sync' | 'async' | 'auto'; decode: () => Promise<void> };

/** Retain only a bounded set of decoded, previously visible public artwork. */
export function createArtworkCache(
  createImage: () => WarmImage,
  maxPixels = 8_000_000,
  maxEntries = 32
) {
  const entries = new Map<string, { image: WarmImage; pixels: number }>();
  let pixels = 0;
  function warm(src: string, width: number, height: number) {
    const existing = entries.get(src);
    if (existing) {
      entries.delete(src);
      entries.set(src, existing);
      return;
    }
    const size = width * height;
    if (
      !/^https?:\/\//.test(src) ||
      !Number.isFinite(size) ||
      width <= 0 ||
      height <= 0 ||
      size > maxPixels
    )
      return;
    while (entries.size && (entries.size >= maxEntries || pixels + size > maxPixels)) {
      const oldest = entries.keys().next().value!;
      pixels -= entries.get(oldest)!.pixels;
      entries.delete(oldest);
    }
    const image = createImage();
    image.decoding = 'sync';
    image.src = src;
    const entry = { image, pixels: size };
    entries.set(src, entry);
    pixels += size;
    void image.decode().catch(() => {
      if (entries.get(src) === entry) {
        entries.delete(src);
        pixels -= size;
      }
    });
  }
  return {
    warm,
    paint(image: {
      src: string;
      currentSrc?: string;
      loading: string;
      decoding: 'sync' | 'async' | 'auto';
    }) {
      if (!entries.has(image.currentSrc || image.src)) return false;
      // Safari otherwise paints text before async-decoded/lazy images on remount,
      // revealing dark empty cards after the native back-swipe preview disappears.
      image.loading = 'eager';
      image.decoding = 'sync';
      return true;
    },
    clear() {
      entries.clear();
      pixels = 0;
    },
    get size() {
      return entries.size;
    },
    get pixels() {
      return pixels;
    }
  };
}

export function artworkContinuity() {
  const cache = createArtworkCache(() => new Image());
  return {
    clear: cache.clear,
    capture(root: HTMLElement | undefined) {
      if (!root) return;
      for (const image of root.querySelectorAll('img')) {
        const rect = image.getBoundingClientRect();
        if (
          !image.complete ||
          !image.naturalWidth ||
          !rect.width ||
          !rect.height ||
          rect.bottom <= 0 ||
          rect.top >= innerHeight ||
          rect.right <= 0 ||
          rect.left >= innerWidth
        )
          continue;
        cache.warm(image.currentSrc || image.src, image.naturalWidth, image.naturalHeight);
      }
    },
    observe(root: HTMLElement) {
      function inspect(node: Node) {
        if (node instanceof HTMLImageElement) cache.paint(node);
        if (node instanceof Element)
          for (const image of node.querySelectorAll('img')) cache.paint(image);
      }
      const observer = new MutationObserver((records) => {
        for (const record of records) {
          if (record.type === 'attributes') inspect(record.target);
          else for (const node of record.addedNodes) inspect(node);
        }
      });
      observer.observe(root, {
        subtree: true,
        childList: true,
        attributes: true,
        attributeFilter: ['src', 'srcset']
      });
      inspect(root);
      return { destroy: () => observer.disconnect() };
    }
  };
}
