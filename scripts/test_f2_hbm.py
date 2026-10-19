"""Check that HBM result classification cannot hide timeouts or missing checks."""

import unittest

import f2_hbm


class HbmResultTests(unittest.TestCase):
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
