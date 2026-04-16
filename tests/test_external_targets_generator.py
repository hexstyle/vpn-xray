#!/usr/bin/env python3

import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "routers" / "common" / "files" / "router-rules-external.py"
SPEC = importlib.util.spec_from_file_location("router_rules_external", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExternalTargetsGeneratorTests(unittest.TestCase):
    maxDiff = None

    def run_generator(self, payload: str) -> list[str]:
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
            handle.write(payload)
            handle.flush()
            temp_path = handle.name
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--input-file", temp_path],
            check=True,
            capture_output=True,
            text=True,
        )
        return [line for line in result.stdout.splitlines() if line]

    def test_extracts_domains_ips_and_cidrs_from_mixed_text(self) -> None:
        payload = textwrap.dedent(
            """
            https://API.example.com/v1/models
            *.Example.NET
            203.0.113.10
            {
              "domains": ["cdn.example.org", "Sub.EXAMPLE.ORG"],
              "cidrs": ["198.51.100.0/24"],
              "links": ["https://downloads.example.io/archive"]
            }
            owner=test@example.com
            notes: already saw cdn.example.org above
            """
        ).strip()

        self.assertEqual(
            self.run_generator(payload),
            [
                "198.51.100.0/24",
                "203.0.113.10",
                "api.example.com",
                "cdn.example.org",
                "downloads.example.io",
                "example.net",
                "sub.example.org",
            ],
        )

    def test_ignores_comments_blank_lines_and_duplicate_targets(self) -> None:
        payload = textwrap.dedent(
            """
            # comment
            Example.com
            example.com

            192.0.2.0/24
            192.0.2.0/24
            https://example.com/path
            """
        ).strip()

        self.assertEqual(
            self.run_generator(payload),
            [
                "192.0.2.0/24",
                "example.com",
            ],
        )

    def test_parses_cloudflare_plain_text_ranges(self) -> None:
        payload = textwrap.dedent(
            """
            173.245.48.0/20
            103.21.244.0/22
            103.22.200.0/22
            """
        ).strip()

        self.assertEqual(
            MODULE.extract_targets(payload, source_url="https://www.cloudflare.com/ips-v4"),
            [
                "103.21.244.0/22",
                "103.22.200.0/22",
                "173.245.48.0/20",
            ],
        )

    def test_expands_multiline_and_comma_separated_urls(self) -> None:
        self.assertEqual(
            MODULE.expand_url_inputs(
                [
                    "https://www.cloudflare.com/ips-v4\nhttps://www.gstatic.com/ipranges/goog.json",
                    "https://ip-ranges.amazonaws.com/ip-ranges.json,https://www.microsoft.com/en-us/download/details.aspx?id=56519",
                ]
            ),
            [
                "https://www.cloudflare.com/ips-v4",
                "https://www.gstatic.com/ipranges/goog.json",
                "https://ip-ranges.amazonaws.com/ip-ranges.json",
                "https://www.microsoft.com/en-us/download/details.aspx?id=56519",
            ],
        )

    def test_parses_google_and_aws_json_ranges(self) -> None:
        goog_payload = textwrap.dedent(
            """
            {
              "syncToken": "1",
              "prefixes": [
                {"ipv4Prefix": "8.8.4.0/24"},
                {"ipv6Prefix": "2001:4860::/32"},
                {"service": "Google Cloud", "ipv4Prefix": "34.64.0.0/10"}
              ]
            }
            """
        ).strip()
        aws_payload = textwrap.dedent(
            """
            {
              "syncToken": "1",
              "prefixes": [
                {"ip_prefix": "3.5.140.0/22", "region": "ap-northeast-2", "service": "AMAZON"},
                {"ip_prefix": "15.230.15.29/32", "service": "ROUTE53_HEALTHCHECKS"}
              ],
              "ipv6_prefixes": [
                {"ipv6_prefix": "2406:da00::/28"}
              ]
            }
            """
        ).strip()

        self.assertEqual(
            MODULE.extract_targets(goog_payload, source_url="https://www.gstatic.com/ipranges/goog.json"),
            [
                "8.8.4.0/24",
                "34.64.0.0/10",
            ],
        )
        self.assertEqual(
            MODULE.extract_targets(aws_payload, source_url="https://ip-ranges.amazonaws.com/ip-ranges.json"),
            [
                "3.5.140.0/22",
                "15.230.15.29/32",
            ],
        )

    def test_collapse_targets_merges_ipv4_networks_but_keeps_domains(self) -> None:
        self.assertEqual(
            MODULE.collapse_targets(
                [
                    "10.0.0.0/25",
                    "10.0.0.128/25",
                    "10.0.1.0/24",
                    "Example.com",
                    "example.com",
                ]
            ),
            [
                "10.0.0.0/23",
                "example.com",
            ],
        )

    def test_resolves_microsoft_download_page_to_service_tags_json(self) -> None:
        microsoft_page = "https://www.microsoft.com/en-us/download/details.aspx?id=56519"
        microsoft_json = "https://download.microsoft.com/download/example/ServiceTags_Public_20260413.json"
        microsoft_html = textwrap.dedent(
            f"""
            <html>
              <body>
                <a data-bi-id="download" href="{microsoft_json}">Download</a>
              </body>
            </html>
            """
        ).strip()
        tags_payload = textwrap.dedent(
            """
            {
              "changeNumber": 123,
              "values": [
                {
                  "name": "AzureCloud.westeurope",
                  "properties": {
                    "addressPrefixes": [
                      "4.144.0.0/12",
                      "20.33.0.0/16",
                      "2603:1030::/36"
                    ]
                  }
                },
                {
                  "name": "AzureFrontDoor.Frontend",
                  "properties": {
                    "addressPrefixes": [
                      "147.243.0.0/16"
                    ]
                  }
                }
              ]
            }
            """
        ).strip()

        responses = {
            microsoft_page: microsoft_html,
            microsoft_json: tags_payload,
        }

        def fetcher(url: str, timeout: float = 45.0) -> str:
            del timeout
            return responses[url]

        self.assertEqual(
            MODULE.extract_targets_from_url(microsoft_page, fetch_text=fetcher),
            [
                "4.144.0.0/12",
                "20.33.0.0/16",
                "147.243.0.0/16",
            ],
        )


if __name__ == "__main__":
    unittest.main()
