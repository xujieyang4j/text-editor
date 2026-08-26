import type { MarketplaceItem } from '../../shared/ipc.js'
import type { Palette, PaletteItem } from './palette.js'

/** Reuses the palette to browse HTTPS declarative plugin marketplaces. */
export async function openMarketplace(
  palette: Palette,
  items: MarketplaceItem[],
  onInstall: (item: MarketplaceItem) => void
): Promise<void> {
  const rows: PaletteItem[] = items.map((item) => ({
    label: item.name,
    detail: item.description ?? item.id,
    hint: item.version,
    value: item
  }))
  palette.open({
    placeholder: 'Browse plugin marketplace…',
    items: rows,
    onAccept: (item) => onInstall(item.value as MarketplaceItem)
  })
}
