/**
 * Deletes Firebase Auth users who:
 * - signed up with email/password only (no Google/Apple/etc. on the same account)
 * - still have emailVerified === false
 * - were created more than UNVERIFIED_MAX_AGE_MS ago (2 hours)
 *
 * Runs on a schedule. Deploy: from repo root, `firebase deploy --only functions`
 * Requires Blaze billing for scheduled functions.
 */

const { initializeApp } = require("firebase-admin/app");
const { getAuth } = require("firebase-admin/auth");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { logger } = require("firebase-functions");

initializeApp();

const UNVERIFIED_MAX_AGE_MS = 2 * 60 * 60 * 1000;

function shouldDelete(user, cutoffMs) {
  if (user.emailVerified) return false;
  if (!user.email) return false;
  const created = new Date(user.metadata.creationTime).getTime();
  if (Number.isNaN(created) || created >= cutoffMs) return false;
  const providers = user.providerData || [];
  if (providers.length === 0) return false;
  const onlyPassword = providers.every((p) => p.providerId === "password");
  return onlyPassword;
}

exports.deleteExpiredUnverifiedUsers = onSchedule(
  {
    schedule: "every 15 minutes",
    timeZone: "Etc/UTC",
    memory: "256MiB",
    timeoutSeconds: 540,
  },
  async () => {
    const auth = getAuth();
    const cutoffMs = Date.now() - UNVERIFIED_MAX_AGE_MS;
    let nextPageToken;
    let deleted = 0;
    let errors = 0;

    try {
      do {
        const result = await auth.listUsers(1000, nextPageToken);
        for (const user of result.users) {
          if (!shouldDelete(user, cutoffMs)) continue;
          try {
            await auth.deleteUser(user.uid);
            deleted += 1;
            logger.info("Deleted unverified user", { uid: user.uid, email: user.email });
          } catch (e) {
            errors += 1;
            logger.error("deleteUser failed", { uid: user.uid, err: String(e) });
          }
        }
        nextPageToken = result.pageToken;
      } while (nextPageToken);
    } catch (e) {
      logger.error("listUsers failed", { err: String(e) });
      throw e;
    }

    logger.info("deleteExpiredUnverifiedUsers finished", { deleted, errors });
  }
);
