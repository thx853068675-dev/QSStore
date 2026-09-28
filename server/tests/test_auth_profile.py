import io
import json
import unittest
from unittest.mock import patch

from hapstore import auth


class _Response(io.BytesIO):
    status = 200


class _Opener:
    def __init__(self, profile):
        self.profile = profile

    def open(self, request, timeout):
        return _Response(json.dumps(self.profile).encode())


class OpenProfileTest(unittest.TestCase):
    def test_uses_profile_nickname_and_checks_account_id(self):
        profile = {"userID": "account-a", "displayName": "公开昵称",
                   "headPictureURL": "https://example.com/huawei-avatar.png",
                   "realName": "不可展示的实名"}
        with patch.object(auth.urllib.request, "build_opener", return_value=_Opener(profile)):
            self.assertEqual(auth._open_display_name("token", "account-a"), "公开昵称")
            self.assertEqual(auth._open_display_name("token", "account-b"), "")
            self.assertEqual(auth._open_profile("token", "account-a"),
                             ("公开昵称", "https://example.com/huawei-avatar.png"))
            self.assertEqual(auth._open_profile("token", "account-b"), ("", ""))


if __name__ == "__main__":
    unittest.main()
