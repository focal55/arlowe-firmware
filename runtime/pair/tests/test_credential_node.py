"""
Cross-implementation check: a credential written by pair.credential (argon2-cffi)
must verify in the dashboard's Node verifier (lib/auth/argon2.ts).

Skips when Node or the dashboard's node_modules is absent, unless
ARLOWE_REQUIRE_NODE is set (the pair-node-compat CI job), where that fails.
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from pair import credential

DASHBOARD = Path(__file__).resolve().parents[3] / "runtime/dashboard"
VERIFY = """
import { loadOwnerCredential } from './lib/auth/credential.ts';
import { verifyPassword } from './lib/auth/argon2.ts';
const cred = await loadOwnerCredential(process.env.CRED_DIR);
console.log(cred !== null && await verifyPassword(cred.hash, process.env.CANDIDATE));
"""


def _node_ready():
    return shutil.which("node") and (DASHBOARD / "node_modules/tsx").is_dir()


pytestmark = pytest.mark.skipif(
    not os.environ.get("ARLOWE_REQUIRE_NODE") and not _node_ready(),
    reason="node or runtime/dashboard/node_modules absent")


@pytest.mark.parametrize("candidate,expected", [("correct horse", "true"),
                                                ("correct horsf", "false")])
def test_python_hash_verifies_in_node(tmp_path, candidate, expected):
    credential.write_owner_credential(tmp_path, "correct horse")
    res = subprocess.run(
        ["node", "--import", "tsx", "--input-type=module", "-e", VERIFY],
        cwd=DASHBOARD, capture_output=True, text=True, timeout=60,
        env={**os.environ, "CRED_DIR": str(tmp_path), "CANDIDATE": candidate})
    assert res.returncode == 0, res.stderr
    assert res.stdout.strip() == expected
