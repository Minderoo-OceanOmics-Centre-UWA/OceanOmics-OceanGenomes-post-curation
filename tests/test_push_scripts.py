"""Phase RG: each post-curation push script writes its own v4 table, in one transaction, and fails
loudly.

Every script runs as __main__ in a temporary folder holding the compiled TSV it expects, with
refdb.connect replaced by a fake that records SQL (tests/fakedb.py). Fixtures in tests/fixtures are
OG762 hic1 241019 stage-3 values in each tool's compiled format. Run: python -m unittest discover tests
"""
import io
import os
import runpy
import shutil
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
FIX = HERE / "fixtures"
COMPILE = REPO / "scripts" / "compile_results"
sys.path.insert(0, str(REPO / "scripts" / "lib"))
sys.path.insert(0, str(HERE))
import refdb  # noqa: E402
from fakedb import FakeConn  # noqa: E402

CURATED = {"og_id": "OG762", "seq_date": "241019", "version": "hic1", "stage": 3}


class PushScriptCase(unittest.TestCase):
    def run_script(self, script, files, conn=None, tsv_override=None):
        conn = conn or FakeConn()
        tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, tmp)
        for name in files:
            shutil.copy(FIX / name, tmp / name)
        for name, text in (tsv_override or {}).items():
            (tmp / name).write_text(text)
        cfg = tmp / "db.cfg"
        cfg.write_text("[postgres]\ndbname=d\nuser=u\npassword=p\nhost=h\nport=5432\n")
        out, cwd, code = io.StringIO(), os.getcwd(), 0
        os.chdir(tmp)
        try:
            with mock.patch.object(sys, "argv", [str(script), str(cfg)]), \
                    mock.patch.object(refdb, "connect", return_value=conn), redirect_stdout(out), redirect_stderr(out):
                runpy.run_path(str(script), run_name="__main__")
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 1
        finally:
            os.chdir(cwd)
        return conn, code, out.getvalue()

    def assert_curated_rows(self, conn, code, out, table, n=2):
        self.assertEqual(code, 0, out[-2000:])
        self.assertEqual((conn.commits, conn.rollbacks), (1, 0))
        self.assertEqual(set(conn.tables_inserted()), {"ref_assembly", "ref_assembly_part", table})
        asm = {p for s, p in conn.statements if s.startswith("INSERT INTO ref_assembly ")}
        self.assertEqual(asm, {("OG762", "241019", "hic1")})
        parts = sorted(p[1:] for s, p in conn.statements if s.startswith("INSERT INTO ref_assembly_part"))
        self.assertEqual(parts, [(3, "hap1"), (3, "hap2")][:n])
        return conn.inserts(table)


class CuratedTools(PushScriptCase):
    def test_merqury_qv(self):
        rows = self.assert_curated_rows(*self.run_script(COMPILE / "02b_push_merqury_qv_results_to_sqldb.py",
                                                         ["merqury.qv.curated.stats.tsv"]), "ref_merqury_qv")
        self.assertEqual([r["qv"] for r in rows], [69.3581, 69.2572])

    def test_merqury_completeness(self):
        rows = self.assert_curated_rows(*self.run_script(COMPILE / "02d_push_merqury_completeness_results_to_sqldb.py",
                                                         ["merqury.completeness.stats.tsv"]), "ref_merqury_completeness")
        self.assertEqual([r["completeness"] for r in rows], [85.2146, 85.1683])

    def test_busco_including_chr_level_hap2(self):
        rows = self.assert_curated_rows(*self.run_script(COMPILE / "03a_push_busco_results_to_sqldb.py",
                                                         ["BUSCO_compiled_results.tsv"]), "ref_busco")
        self.assertEqual([r["percent_gaps"] for r in rows], [0.010, 0.012])

    def test_gfastats_with_num_gaps(self):
        rows = self.assert_curated_rows(*self.run_script(COMPILE / "04a_push_gfa_results_to_sqldb.py",
                                                         ["final_gfastats_report.txt"]), "ref_gfastats")
        self.assertEqual([r["num_gaps"] for r in rows], [132, 106])

    def test_seqkit_stats(self):
        rows = self.assert_curated_rows(*self.run_script(COMPILE / "05a_push_stats_compiled_results_to_sql.py",
                                                         ["stats_compiled.tsv"]), "ref_seqkit_stats")
        self.assertEqual([(r["type"], r["num_seqs"], r["sum_len"]) for r in rows],
                         [("DNA", 288, 1731700000), ("DNA", 224, 1646120000)])

    def test_chromosome_stats(self):
        rows = self.assert_curated_rows(*self.run_script(COMPILE / "06b_push_percentage_stats_to_sqldb.py",
                                                         ["percentage_stats_split.tsv"]), "ref_chromosome_stats")
        self.assertEqual([r["pct_assigned"] for r in rows], [95.42, 97.53])


class Failures(PushScriptCase):
    def test_database_error_exits_1_and_rolls_back(self):
        conn, code, out = self.run_script(COMPILE / "04a_push_gfa_results_to_sqldb.py", ["final_gfastats_report.txt"],
                                          conn=FakeConn(fail_on="INSERT INTO ref_gfastats"))
        self.assertEqual(code, 1)
        self.assertEqual((conn.commits, conn.rollbacks), (0, 1))

    def test_bad_version_exits_1_and_commits_nothing(self):
        bad = (FIX / "percentage_stats_split.tsv").read_text().replace("\thic1\t3\thap2", "\thi1\t3\thap2")
        conn, code, out = self.run_script(COMPILE / "06b_push_percentage_stats_to_sqldb.py", [],
                                          tsv_override={"percentage_stats_split.tsv": bad})
        self.assertEqual(code, 1)
        self.assertEqual(conn.commits, 0)
        self.assertIn("version 'hi1'", out)


if __name__ == "__main__":
    unittest.main()
