//see: https://github.com/followingthefasciaplane/MomSurfFix-API/

#if defined _momsurffix2_included_
  #endinput
#endif
#define _momsurffix2_included_

/**
 * Called at the start of each bump iteration in TryPlayerMove.
 *
 * @param client        The client index.
 * @param bumpcount     The current bump iteration count.
 * @param velocity      The current velocity vector (can be modified).
 * @param origin        The current origin vector (can be modified).
 * @return              Plugin_Continue to allow the default behavior.
 *                      Plugin_Changed to use the modified velocity and origin.
 *                      Plugin_Handled to skip this iteration.
 */
forward Action MomSurfFix_OnBumpIteration(int client, int bumpcount, float velocity[3], float origin[3]);

/**
 * Called when a player is detected as stuck on a ramp.
 *
 * @param client        The client index.
 * @param velocity      The current velocity vector.
 * @param origin        The current origin vector.
 * @param validPlane    The valid plane normal vector.
 */
forward void MomSurfFix_OnPlayerStuckOnRamp(int client, float velocity[3], float origin[3], float validPlane[3]);

/**
 * Called before performing ClipVelocity.
 *
 * @param client        The client index.
 * @param inVelocity    The input velocity vector.
 * @param normal        The surface normal vector.
 * @param overbounce    The overbounce factor (can be modified).
 * @return              Plugin_Continue to allow the default behavior.
 *                      Plugin_Changed to use the modified overbounce value.
 *                      Plugin_Handled to skip the default ClipVelocity calculation.
 */
forward Action MomSurfFix_OnClipVelocity(int client, float inVelocity[3], float normal[3], float& overbounce);

/**
 * Called at the end of TryPlayerMove.
 *
 * @param client        The client index.
 * @param blocked       The blocked status.
 * @param endVelocity   The final velocity vector.
 * @param endOrigin     The final origin vector.
 * @param allFraction   The total fraction moved.
 */
forward void MomSurfFix_OnTryPlayerMovePost(int client, int blocked, float endVelocity[3], float endOrigin[3], float allFraction);

/**
 * Called when the MomSurfFix2 plugin is fully loaded and ready.
 */
forward void MomSurfFix_OnPluginReady();
