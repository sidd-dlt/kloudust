/**
 * addHostStorage.js - Mounts the cloud's shared storage (NAS) on a host at /kloudust/shared and
 *                     moves the host's shared resources (disks, metadata, snapshots, catalog,
 *                     recyclebin) onto it. Running VMs are moved live, nothing is stopped.
 *                     All hosts must mount the same storage.
 *
 * Params - 0 - hostname, 1 - storage type (nfs or cifs), 2 - storage server IP or DNS,
 *  3 - NFS export path or CIFS share name, 4 - CIFS user ID, 5 - CIFS password
 *
 * (C) 2026 TekMonks. All rights reserved.
 * License: See enclosed LICENSE file.
 */
const roleman = require(`${KLOUD_CONSTANTS.LIBDIR}/roleenforcer.js`);
const dbAbstractor = require(`${KLOUD_CONSTANTS.LIBDIR}/dbAbstractor.js`);
const {xforge} = require(`${KLOUD_CONSTANTS.THIRD_PARTY_DIR}/xforge/xforge`);
const CMD_CONSTANTS = require(`${KLOUD_CONSTANTS.LIBDIR}/cmd/cmdconstants.js`);

/**
 * Mounts the shared storage on the given host
 * @param {array} params The incoming params, see above
 */
module.exports.exec = async function(params) {
    if (!roleman.checkAccess(roleman.ACTIONS.edit_cloud_resource)) {params.consoleHandlers.LOGUNAUTH(); return CMD_CONSTANTS.FALSE_RESULT();}

    const [hostname, type, address, path, userid, password] = [...params];
    const hostInfo = await dbAbstractor.getHostEntry(hostname);
    if (!hostInfo) {params.consoleHandlers.LOGERROR("Bad hostname or host not found"); return CMD_CONSTANTS.FALSE_RESULT();}

    const storage = exports.normalizeStorage(type, address, path, userid, password);
    const error = exports.validateStorage(storage);
    if (error) {params.consoleHandlers.LOGERROR(error); return CMD_CONSTANTS.FALSE_RESULT(error);}

    return exports.addStorageToHost(hostname, hostInfo.hostaddress, hostInfo.rootid, hostInfo.rootpw, hostInfo.hostkey,
        hostInfo.port, storage, params.consoleHandlers);
}

/** @return The storage object with trimmed fields and a lowercase type */
exports.normalizeStorage = (type, address, path, userid, password) => ({type: (type||"").trim().toLowerCase(),
    address: (address||"").trim(), path: (path||"").trim(), userid: (userid||"").trim(), password: password||""});

/**
 * Validates the storage details, they end up inside a shell script on the host so only safe characters are allowed.
 * The password is passed base64 encoded, so it can contain anything.
 * @return An error message, or undefined if the storage is valid
 */
exports.validateStorage = ({type, address, path, userid}) => {
    if (!["nfs", "cifs"].includes(type)) return "Storage type must be nfs or cifs.";
    if (!/^[A-Za-z0-9.\-]+$/.test(address)) return "Bad storage server address, use an IPv4 address or a DNS name.";
    if (!/^[A-Za-z0-9._\/\-]+$/.test(path)) return "Bad storage path or share name.";
    if (type == "cifs" && !/^[A-Za-z0-9._@\-]+$/.test(userid)) return "CIFS storage needs a valid user ID.";
}

/**
 * Runs the shared storage setup script on the given host and saves the storage to the DB
 * @param {object} agent_config Optional, the agent to run it through, addHost passes the one it just set up
 * @return The xforge results
 */
exports.addStorageToHost = async (hostname, hostaddress, rootid, rootpw, hostkey, port, storage, consoleHandlers, agent_config) => {
    const results = await xforge({
        colors: KLOUD_CONSTANTS.COLORED_OUT,
        file: `${KLOUD_CONSTANTS.THIRD_PARTY_DIR}/xforge/samples/remoteCmd.xf.js`,
        console: consoleHandlers,
        agent_config,
        other: [
            hostaddress, rootid, rootpw, hostkey, port,
            `${KLOUD_CONSTANTS.LIBDIR}/cmd/scripts/setupSharedStorage.sh`,
            storage.type, storage.address, storage.path, storage.userid, Buffer.from(storage.password).toString("base64")
        ]
    });
    if (!results.result) return results;

    const storageSize = parseInt((results.stdout.match(/KD_SHARED_STORAGE_SIZE=(\d+)/)||[])[1]);   // printed by the script
    if (!await dbAbstractor.addHostStorageToDB(hostname, storage.type, storage.address, storage.path, storage.userid, storage.password, storageSize)) {
        consoleHandlers.LOGERROR(`Shared storage is mounted on ${hostname} but the database update failed.`);
        return {...results, result: false};
    }
    return results;
}
