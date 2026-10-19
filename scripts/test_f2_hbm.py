"""Check that HBM result classification cannot hide timeouts or missing checks."""

import unittest

import f2_hbm


class HbmResultTests(unittest.TestCase):
    def test_filter_removes_only_identified_timing_warning_lines(self):
        warnings = (
            "HBM[CH_F] : Warning tCHmax violation at 31611.9760 ns. tCH is 0.5560 ns\n"
            "IEEE1500  : Warning tWRSTL violation on WRST_n    at 20875.0280 ns\n"
            "IEEE1500  : Warning tHF violation on UpdateWR  at 21225.0280 ns\n"
        )
        diagnostics = (
            "HBM[CH_F] : Warning tRCD violation at 31611.9760 ns\n"
            "Fatal: HBM_DATA_MISMATCH\n"
            "F2_HBM_PASS ports=32\n"
        )
        filtered, count = f2_hbm.filter_timing_warnings(warnings + diagnostics)
        self.assertEqual(filtered, diagnostics)
        self.assertEqual(count, 3)
        self.assertFalse(f2_hbm.classify(0, filtered, None))

    def test_filter_preserves_extra_diagnostics_on_a_warning_line(self):
        content = (
            "HBM[CH_F] : Warning tCHmax violation at 31611.9760 ns. tCH is 0.5560 ns "
            "Fatal: HBM_DATA_MISMATCH\n"
        )
        self.assertEqual(f2_hbm.filter_timing_warnings(content), (content, 0))

    def test_positive_requires_success_and_explicit_completion(self):
        self.assertTrue(f2_hbm.classify(0, "F2_HBM_PASS ports=32", None))
        self.assertFalse(f2_hbm.classify(0, "simulation finished", None))
        self.assertFalse(f2_hbm.classify(1, "F2_HBM_PASS ports=32", None))
        self.assertFalse(f2_hbm.classify(0, "Fatal: failed\nF2_HBM_PASS ports=32", None))
        self.assertFalse(f2_hbm.classify(0, "HBM: Error: failure\nF2_HBM_PASS ports=32", None))

    def test_negative_requires_the_specific_failure_and_nonzero_exit(self):
        self.assertTrue(f2_hbm.classify(1, "HBM_DATA_MISMATCH", "HBM_DATA_MISMATCH"))
        self.assertFalse(f2_hbm.classify(0, "HBM_DATA_MISMATCH", "HBM_DATA_MISMATCH"))
        self.assertFalse(f2_hbm.classify(1, "license checkout failed", "HBM_DATA_MISMATCH"))

    def test_timeout_never_counts_as_an_expected_negative(self):
        self.assertFalse(f2_hbm.classify(124, "HBM_DATA_MISMATCH", "HBM_DATA_MISMATCH"))


if __name__ == "__main__":
    unittest.main()
