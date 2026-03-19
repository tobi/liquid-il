# frozen_string_literal: true

require "minitest/autorun"

# Reproduces the logic of 4 liquid-spec benchmark templates in plain Ruby
# to demonstrate that:
#   1. The rendered output contains all expected keywords
#   2. The expected_pattern regex fails WITHOUT Regexp::MULTILINE
#   3. The expected_pattern regex passes WITH Regexp::MULTILINE
#
# Filed as: https://github.com/Shopify/liquid-spec/issues/XXX
#
# The fix is trivial: add (?m) to each pattern, as the storefront benchmarks
# already do (e.g. bench_storefront_product_page uses (?m) and passes).

class LiquidSpecRegexBugTest < Minitest::Test
  # ── bench_online_store_page ──────────────────────────────────────────
  # Template renders an HTML product page. All keywords appear, but on
  # separate lines — `.*` without multiline flag can't bridge newlines.

  def test_online_store_page_keywords_present_but_regex_fails
    # Simulate the rendered output (just the relevant lines)
    output = <<~HTML
      <title>Premium Wireless Earbuds Pro | TechGear Store</title>
      <h1>Premium Wireless Earbuds Pro</h1>
      <button class="add-to-cart">Add to Cart - $149</button>
      <h2>You May Also Like</h2>
    HTML

    # All keywords are present
    assert_includes output, "TechGear Store"
    assert_includes output, "Premium Wireless Earbuds"
    assert_includes output, "Add to Cart"
    assert_includes output, "You May Also Like"

    # Pattern from liquid-spec (no multiline flag)
    pattern_str = "TechGear Store.*Premium Wireless Earbuds.*Add to Cart.*You May Also Like"

    # BUG: fails without Regexp::MULTILINE because .* doesn't match \n
    refute_match Regexp.new(pattern_str), output,
      "Should NOT match without MULTILINE (this is the bug — .* can't cross newlines)"

    # FIX: passes with Regexp::MULTILINE
    assert_match Regexp.new(pattern_str, Regexp::MULTILINE), output,
      "Should match with MULTILINE — all keywords are present in order"
  end

  # ── bench_order_confirmation ─────────────────────────────────────────
  # Template renders an order confirmation email. Same issue.

  def test_order_confirmation_keywords_present_but_regex_fails
    output = <<~HTML
      <h1>Order Confirmation</h1>
      <p>Order #TG-12345</p>
      <td>Wireless Earbuds Pro</td>
      <tr class="total"><td>Total</td><td>$318.00</td></tr>
    HTML

    assert_includes output, "Order Confirmation"
    assert_includes output, "TG-12345"
    assert_includes output, "Wireless Earbuds"
    assert_includes output, "Total"
    assert_includes output, "318"

    pattern_str = "Order Confirmation.*TG-12345.*Wireless Earbuds.*Total.*318"

    refute_match Regexp.new(pattern_str), output
    assert_match Regexp.new(pattern_str, Regexp::MULTILINE), output
  end

  # ── bench_product_grid ───────────────────────────────────────────────
  # Template renders a product grid with pagination. Same issue.

  def test_product_grid_keywords_present_but_regex_fails
    output = <<~HTML
      <div class="product-grid">
        <article>Product 1</article>
        <article>Product 2</article>
      </div>
      <nav class="pagination">
        <a href="?page=2">Next</a>
      </nav>
    HTML

    assert_includes output, "product-grid"
    assert_includes output, "pagination"

    pattern_str = "product-grid.*pagination"

    refute_match Regexp.new(pattern_str), output
    assert_match Regexp.new(pattern_str, Regexp::MULTILINE), output
  end

  # ── bench_collection_with_filters ────────────────────────────────────
  # This one has TWO bugs:
  #   1. Missing Regexp::MULTILINE (same as above)
  #   2. Pattern expects "pagination" but the test environment has
  #      total_pages=nil, so the {% if total_pages > 1 %} block never
  #      renders, and "pagination" never appears in the output.

  def test_collection_with_filters_pagination_impossible
    # The template's pagination section:
    #   {% if total_pages > 1 %}
    #     <nav class="pagination">...</nav>
    #   {% endif %}
    #
    # But the test environment provides:
    #   total_pages: nil
    #   current_page: 1
    #
    # nil > 1 is always false in Liquid, so pagination never renders.

    total_pages = nil
    current_page = 1

    # Simulate Liquid's comparison: nil > 1 → false
    pagination_renders = !total_pages.nil? && total_pages > 1

    refute pagination_renders,
      "pagination section cannot render when total_pages is nil"

    # Build what the output would contain
    output = "<div class=\"collection\">Electronics products Showing 8 products</div>"
    # Note: no "pagination" anywhere

    assert_includes output, "Electronics"
    assert_includes output, "Showing"
    assert_includes output, "products"
    refute_includes output, "pagination",
      "pagination keyword is impossible — total_pages is nil in test environment"

    pattern_str = "Electronics.*Showing.*products.*pagination"

    # Even with MULTILINE, this can never match — "pagination" isn't in the output
    refute_match Regexp.new(pattern_str, Regexp::MULTILINE), output,
      "Pattern requires 'pagination' but it's impossible with the given test data"
  end

  # ── Contrast: storefront benchmarks already use (?m) ─────────────────
  # The storefront_* benchmarks (added later) correctly include (?m).
  # This test documents the working pattern for reference.

  def test_multiline_flag_in_pattern_string_works
    output = "line one\nline two\nline three"

    # Without (?m) embedded in the pattern string
    refute_match Regexp.new("one.*three"), output

    # With (?m) embedded — this is how storefront benchmarks do it
    assert_match Regexp.new("(?m)one.*three"), output
  end
end
