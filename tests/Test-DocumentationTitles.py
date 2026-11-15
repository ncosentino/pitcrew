import collections
from html.parser import HTMLParser
from pathlib import Path
import sys


class Metadata(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.in_head = False
        self.in_title = False
        self.in_h1 = False
        self.title = []
        self.heading = []
        self.social = {}

    def handle_starttag(self, tag, attrs):
        if tag == "head":
            self.in_head = True
        elif tag == "title" and self.in_head:
            self.in_title = True
        elif tag == "h1":
            self.in_h1 = True
        elif tag == "meta" and self.in_head:
            attrs = dict(attrs)
            name = attrs.get("property") or attrs.get("name")
            if name in ("og:title", "twitter:title"):
                self.social[name] = attrs.get("content")

    def handle_endtag(self, tag):
        if tag == "head":
            self.in_head = False
        elif tag == "title":
            self.in_title = False
        elif tag == "h1":
            self.in_h1 = False

    def handle_data(self, data):
        if self.in_title:
            self.title.append(data)
        if self.in_h1:
            self.heading.append(data)


def main():
    site = Path(sys.argv[1] if len(sys.argv) > 1 else "site")
    expected = {
        "adr/index.html": "Architecture Decision Records",
        "guides/index.html": "Guides",
    }
    titles = collections.defaultdict(list)
    pages = sorted(site.rglob("*.html"))
    assert pages, f"No HTML pages in {site}"
    for path in pages:
        relative = path.relative_to(site).as_posix()
        if relative == "404.html" or relative.startswith("overrides/"):
            continue
        metadata = Metadata()
        metadata.feed(path.read_text(encoding="utf-8"))
        title = "".join(metadata.title).strip()
        assert title, f"Missing title: {relative}"
        titles[title].append(relative)
        if relative in expected:
            heading = expected[relative]
            assert title == f"{heading} - PitCrew", (relative, title)
            for key in ("og:title", "twitter:title"):
                assert metadata.social[key] == f"{heading} \u2013 PitCrew", (
                    relative, key, metadata.social
                )
            assert "".join(metadata.heading).strip().removesuffix("\u00b6").strip() == heading, (
                relative, metadata.heading
            )
    for relative in expected:
        assert (site / relative).is_file(), f"Missing page: {relative}"
    duplicates = {title: paths for title, paths in titles.items() if len(paths) > 1}
    assert not duplicates, f"Duplicate documentation titles: {duplicates}"
    print(f"Verified {len(titles)} unique documentation titles")


if __name__ == "__main__":
    main()
