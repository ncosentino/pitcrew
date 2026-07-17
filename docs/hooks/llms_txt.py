"""MkDocs build hook: auto-generate llms.txt at build time.

Walks the site nav, collects each page's title and description (from front
matter or the global site_description fallback), then writes site/llms.txt
following the llmstxt.org convention. The file stays in sync automatically as
pages are added, removed, or re-described.
"""

from pathlib import Path


_PAGE_DESCRIPTIONS: dict[str, tuple[str, str]] = {}


def on_page_context(context, page, config, nav) -> None:
    """Collect each page's description as pages are processed."""
    if page.meta and page.meta.get('description'):
        desc = page.meta['description']
    else:
        desc = config.get('site_description', '')
    _PAGE_DESCRIPTIONS[page.url or ''] = (page.title or '', desc)


def on_post_build(config) -> None:
    """Write site/llms.txt after the full build completes."""
    site_url = config.get('site_url', '').rstrip('/')
    site_name = config.get('site_name', '')
    site_description = config.get('site_description', '')
    nav = config.get('nav', [])

    preamble = (
        f'# {site_name}\n\n'
        f'> {site_description}\n\n'
        'Author: Nick Cosentino (https://www.devleader.ca).\n\n'
    )
    lines: list[str] = [preamble]

    def _section_header(title: str) -> str:
        return f'\n## {title}\n\n'

    def _page_line(url: str) -> str:
        url_clean = url.strip('/')
        if url_clean:
            full_url = f'{site_url}/{url_clean}'
        else:
            full_url = site_url
        title, desc = _PAGE_DESCRIPTIONS.get(url, (url, ''))
        if desc:
            return f'- [{title}]({full_url}) -- {desc}\n'
        return f'- [{title}]({full_url})\n'

    def _url_from_path(md_path: str) -> str | None:
        """Convert a docs-relative .md path to its URL segment."""
        if md_path.lower().endswith('readme.md'):
            return None
        url = md_path.replace('.md', '/')
        if url == 'index/':
            url = ''
        url = url.replace('index/', '')
        return url

    def _walk_nav(nav_items) -> None:
        for item in nav_items:
            if isinstance(item, dict):
                for section_title, children in item.items():
                    if isinstance(children, list):
                        lines.append(_section_header(section_title))
                        _walk_nav(children)
                    elif isinstance(children, str):
                        page_url = _url_from_path(children)
                        if page_url is not None:
                            lines.append(_page_line(page_url))
            elif isinstance(item, str):
                page_url = _url_from_path(item)
                if page_url is not None:
                    lines.append(_page_line(page_url))

    _walk_nav(nav)

    output_path = Path(config['site_dir']) / 'llms.txt'
    output_path.write_text(''.join(lines), encoding='utf-8')
