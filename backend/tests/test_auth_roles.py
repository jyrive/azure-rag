import os
import unittest
from unittest.mock import patch

from app.main import get_default_app_role, me, merge_principal_and_app_roles


class AuthRoleTests(unittest.TestCase):
    def test_default_app_role_uses_member_fallback(self) -> None:
        previous = os.environ.get("DEFAULT_APP_ROLE")
        try:
            os.environ["DEFAULT_APP_ROLE"] = ""
            self.assertEqual(get_default_app_role(), "member")
        finally:
            if previous is None:
                os.environ.pop("DEFAULT_APP_ROLE", None)
            else:
                os.environ["DEFAULT_APP_ROLE"] = previous

    def test_default_app_role_is_normalized(self) -> None:
        previous = os.environ.get("DEFAULT_APP_ROLE")
        try:
            os.environ["DEFAULT_APP_ROLE"] = " Company Admin "
            self.assertEqual(get_default_app_role(), "companyadmin")
        finally:
            if previous is None:
                os.environ.pop("DEFAULT_APP_ROLE", None)
            else:
                os.environ["DEFAULT_APP_ROLE"] = previous

    def test_merge_principal_and_app_roles(self) -> None:
        merged = merge_principal_and_app_roles({"administrator", "authenticated"}, ["member", "companyadmin"])
        self.assertEqual(merged, {"administrator", "authenticated", "member", "companyadmin"})

    def test_merge_filters_invalid_app_roles(self) -> None:
        merged = merge_principal_and_app_roles({"authenticated"}, ["", "member", " ", "member"])
        self.assertEqual(merged, {"authenticated", "member"})

    def test_me_falls_back_when_profile_lookup_fails(self) -> None:
        fake_principal = {
            "userDetails": "test@example.com",
            "userId": "123",
            "identityProvider": "aad",
            "userRoles": ["administrator"],
        }

        with patch("app.main.decode_client_principal", return_value=fake_principal), patch(
            "app.main.resolve_tenant_context_with_app_roles",
            side_effect=RuntimeError("profile store down"),
        ):
            response = me("fake-token")

        self.assertTrue(response["authenticated"])
        self.assertEqual(response["roles"], ["administrator", "authenticated"])
        self.assertEqual(response["appRoles"], [])
        self.assertEqual(response["principal"], fake_principal)


if __name__ == "__main__":
    unittest.main()
