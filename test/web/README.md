# LiquidIL Web Flex Demo

A fun local web app that renders a Shopify-style theme using **LiquidIL**.

- Uses real benchmark templates copied from `liquid-spec/specs/benchmarks/theme_*.yml`
- Uses snippet includes (`product-card.liquid`) through a Liquid-compatible file system API
- Runs with either **WEBrick/rackup** or **Falcon**

## Files

- `app.rb` — Rack app + theme file system + sample data
- `config.ru` — Rack entrypoint
- `theme/templates/*.liquid` — copied benchmark templates
- `theme/snippets/product-card.liquid` — shared snippet from benchmark
- `public/theme.css` — styling
- `bin/server` — rackup/WEBrick launcher
- `bin/falcon` — Falcon launcher

## Run

```bash
cd test/web
bundle install

# Rackup / WEBrick
./bin/server

# or Falcon
./bin/falcon
```

Open: <http://localhost:9292>

## Routes

- `/` home page (benchmark index template)
- `/collections/all`
- `/products/synergistic-wooden-car`
- `/search?q=wooden`
- `/cart`
- `/blogs/news`
- `/__bench` tiny in-app benchmark loop

## Notes

- This demo registers a few Shopify-ish filters (`money`, `product_img_url`, `img_url`, `default_pagination`, `asset_url`, `handle`) for theme compatibility.
- The file system implements `read_template_file(name, context = nil)` so it works with normal Liquid file system expectations and lazy-loads snippets from disk.
