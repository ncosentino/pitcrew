"""Exercise source-derived descriptions through the real documentation templates."""

from html.parser import HTMLParser
import json
from pathlib import Path
import re
import tempfile
import unittest

from mkdocs.commands.build import build
from mkdocs.config import load_config

ROOT = Path(__file__).resolve().parents[1]


class Metadata(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.in_head = False
        self.values = {}

    def handle_starttag(self, tag, attrs):
        if tag == 'head':
            self.in_head = True
        elif tag == 'meta' and self.in_head:
            attrs = dict(attrs)
            name = attrs.get('property') or attrs.get('name')
            if name:
                self.values.setdefault(name, []).append(attrs.get('content'))
        elif tag == 'link' and self.in_head:
            attrs = dict(attrs)
            if attrs.get('rel') == 'canonical':
                self.values.setdefault('canonical', []).append(attrs.get('href'))

    def handle_endtag(self, tag):
        if tag == 'head':
            self.in_head = False


class DocumentationMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.workspace = tempfile.TemporaryDirectory(dir=ROOT)
        cls.addClassCleanup(cls.workspace.cleanup)
        root = Path(cls.workspace.name)
        docs = root / 'docs'
        cls.site = root / 'site'
        pages = {
            'index.md': '# Home\n',
            'guide.md': (
                '# Guide\n\n> Ignore this note.\n\n'
                '![Diagram](https://example.test/diagram.png)\n\n'
                'Use `Factory<T>` with **services** &amp; "plugins".\n\nIgnore later prose.\n'
            ),
            'authored.md': (
                '---\ndescription: \'Explicit "quoted" <T> & safe summary.\'\n---\n'
                '# Authored\n\nIgnore this introduction.\n'
            ),
            'blank.md': "---\ndescription: '   '\n---\n# Blank\n\nRegister services.\n",
            'empty.md': '# Empty\n\n```text\nnot introductory prose\n```\n',
            'generic,A.md': '# Generic A\n\nRead the generated reference.\n',
            'long.md': '# Long\n\n' + 'Register services and manage application lifetimes. ' * 15,
            'getting-started.md': (
                '# Getting Started\n\nUse `</script>` &amp; "plugins".\n\n'
                '## Configure\n\nRegister services.\n'
            ),
            'guides/safety.md': (
                "---\ntitle: 'Safety </script>'\n---\n"
                '# Safety\n\nUse safe workers.\n\n'
                '## Configure\n\nUse `</script>` &amp; "plugins".\n'
            ),
        }
        for source, content in pages.items():
            path = docs / source
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding='utf-8')
        config = load_config(
            config_file=str(ROOT / 'mkdocs.yml'), docs_dir=str(docs),
            site_dir=str(cls.site), site_url='https://example.test/docs/',
            nav=list(pages), extra_javascript=[],
        )
        cls.site_name = config.site_name
        cls.home_description = config.site_description
        build(config)

    def read(self, source):
        path = self.site / ('index.html' if source == 'index' else f'{source}/index.html')
        html = path.read_text(encoding='utf-8')
        metadata = Metadata()
        metadata.feed(html)
        return html, metadata.values

    def description(self, source):
        _, values = self.read(source)
        result = values.get('description', [])
        self.assertEqual(len(result), 1, source)
        for tag in ('og:description', 'twitter:description'):
            self.assertEqual(values.get(tag), result, (source, tag))
        return result[0]

    def test_intro_preserves_inline_text_and_skips_notes_and_images(self):
        self.assertEqual(self.description('guide'),
                         'Guide. Use Factory<T> with services & "plugins".')

    def test_authored_override_is_preserved_and_safely_rendered(self):
        self.assertEqual(self.description('authored'), 'Explicit "quoted" <T> & safe summary.')

    def test_homepage_preserves_project_description(self):
        self.assertEqual(self.description('index'), self.home_description)

    def test_blank_override_derives_intro(self):
        self.assertEqual(self.description('blank'), 'Blank. Register services.')

    def test_missing_prose_has_truthful_identity_fallback(self):
        self.assertEqual(self.description('empty'), f'{self.site_name}: Empty.')

    def test_long_intro_ends_at_word_boundary(self):
        description = self.description('long')
        self.assertLessEqual(len(description), 240)
        self.assertTrue(description.endswith('...'))
        self.assertRegex(description[:-3], r'(Register|services|and|manage|application|lifetimes\.)$')

    def test_existing_headings_are_preserved(self):
        html, _ = self.read('guide')
        self.assertRegex(html, r'<h1[^>]*>Guide(?:<a[^>]*>.*?</a>)?</h1>')
        self.assertIn('Ignore later prose.', html)

    def schemas(self, source):
        html, _ = self.read(source)
        scripts = re.findall(r'<script type="application/ld\+json">\s*(.*?)\s*</script>',
                             html, re.DOTALL)
        return [json.loads(script) for script in scripts]

    def test_page_identity_reuses_rendered_metadata_and_canonical(self):
        for source, title in (
            ('index', 'Home'), ('guide', 'Guide'), ('authored', 'Authored'),
            ('empty', 'Empty'), ('getting-started', 'Getting Started'), ('generic,A', 'Generic A'),
        ):
            with self.subTest(source=source):
                _, metadata = self.read(source)
                pages = [schema for schema in self.schemas(source) if schema.get('@type') == 'WebPage']
                self.assertEqual(len(pages), 1)
                page = pages[0]
                suffix = '' if source == 'index' else '/' + source.replace(',', '%2C')
                expected = 'https://example.test/docs' + suffix
                self.assertEqual(metadata.get('canonical'), [expected])
                self.assertEqual(metadata.get('og:url'), [expected])
                self.assertEqual(page['@id'], expected)
                self.assertEqual(page['url'], expected)
                self.assertEqual(page['name'], title)
                self.assertEqual(page['description'], self.description(source))

    def test_source_description_stays_plain_and_safe_in_howto_json_ld(self):
        howto = next(schema for schema in self.schemas('getting-started')
                     if schema.get('@type') == 'HowTo')
        self.assertEqual(howto['description'], self.description('getting-started'))
        self.assertIn('</script>', howto['description'])

    def test_faq_json_ld_cannot_close_its_script(self):
        faq = next(schema for schema in self.schemas('guides/safety')
                   if schema.get('@type') == 'FAQPage')
        self.assertIn('</script>', faq['mainEntity'][0]['name'])

    def test_llms_description_is_plain_source_text(self):
        llms = (self.site / 'llms.txt').read_text(encoding='utf-8')
        self.assertIn(' -- ' + self.description('guide') + '\n', llms)
        self.assertIn(' -- ' + self.description('authored') + '\n', llms)


if __name__ == '__main__':
    unittest.main()
