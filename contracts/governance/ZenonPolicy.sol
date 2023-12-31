// SPDX-License-Identifier: MIT                                                    
pragma solidity 0.8.19;

import '../libraries/ProtocolCmd.sol';
import '../interfaces/IZenonMinion.sol';
import '../mixins/StorageLayout.sol';
import '../vendor/compound/Timelock.sol';
import '../ZenonSwapDex.sol';

/* @title ZenonPolicy
 * @notice Intermediates between the dex mechanism inside ZenonSwapDex and the top-level
 *         protocol governance. Governance sets policy, which controls the parameters
 *         inside the dex mechanism. All policy routes through calls to protocolCmd() 
 *         method in ZenonSwapDex. Policy can be either through governance resolutions, 
 *         which directly call protocolCmd() with a preset command. Or policy can be
 *         set based on rules, which allow arbitrary oracles to independently invoke 
 *         protocolCmd() for some restricted subset of command types. */
contract ZenonPolicy is IZenonMaster {
    using ProtocolCmd for bytes;


    /* @notie Emitted whenever the governance authority is set on this contract (either
     *        at construction time or by later call). */
    event ZenonGovernAuthority (address ops, address treasury, address emergency);

    /* @notice Emitted whenever ops authority runs a protocol command. 
     * @param minion The underlying receiver of the protocol command (i.e. the 
     *               ZenonSwapDex contract).
     * @param cmd The command being called on the minion's protocolCmd() function. */
    event ZenonResolutionOps (address minion, bytes cmd);

    /* @notice Emitted whenever treasury authority runs a protocol command. 
     * @param minion The underlying receiver of the protocol command (i.e. the 
     *               ZenonSwapDex contract).
     * @param sudo If true, calls the command on ZenonSwapDex with elevated privilege
     * @param cmd The command being called on the minion's protocolCmd() function. */
    event ZenonResolutionTreasury (address minion, bool sudo, bytes cmd);

    /* @notice Emitted when an emergency halt is invoked.
     * @param minion The underlying receiver of the protocol commands to disable the
     *               proxy contracts (see emergencyHalt() below)
     * @param reason The stated reason for invoking the emergencyHalt() with details. */
    event ZenonEmergencyHalt (address minion, string reason);

    /* @notice Emitted when a new policy rule is set or updated.
     * @param conduit The policy conduit the rule applies to
     * @param proxyPath The proxy sidecar index the policy can call
     * @param PolicyRule The policy rules set for this conduit (see PolicyRule comments
     *                   below). */
    event ZenonPolicySet (address conduit, uint16 proxyPath, PolicyRule);

    /* @notice Emitted when a new policy rule is force updated. This has the same outcome
     *         but can override a policy mandate time. Should not be called in normal
     *         course of operations.
     * @param conduit The policy conduit the rule applies to
     * @param proxyPath The proxy sidecar index the policy can call
     * @param PolicyRule The policy rules set for this conduit (see PolicyRule comments
     *                   below). */
    event ZenonPolicyForce (address conduit, uint16 proxyPath, PolicyRule);

    /* @notice Invoked by emergency authority to revoke all authority vested to a policy
     *         conduit oracle. 
     * @param conduit The policy conduit being reset.
     * @param reason The stated reason for invoking the emergency policy update with 
     *               details. */
    event ZenonPolicyEmergency (address conduit, string reason);

    
    /* @notice Operations authority has the ability to set policy rules for external
     *         oracle conduits and to directly invoke non-privileged protocol commands
     *         (i.e. anything but authority transfers, proxy upgrades or protocol 
     *          treasury collection.) */
    address public opsAuthority_;

    /* @notice Treasury authority is a superset of operations authority, with the 
     *         additional power to call privileged protocol commands on the dex (i.e. 
     *         authority transfer, proxy upgrades and treasury disbursement.). In 
     *         addition the treasury authority can transfer the authority of the policy
     *         contract. */
    address public treasuryAuthority_;

    /* @notice Emergency is a special purpose authority with the following powers:
     *            1) Invoke partial halt on the underlying ZenonSwapDex
     *            2) Force reset policy rules.
     *            3) Issue any resolutions that ops is authorized to. */
    address public emergencyAuthority_;

    address public immutable dex_;

    
    /* @param dex Underlying ZenonSwapDex contract */
    constructor (address dex) {
        require(dex != address(0) && ZenonSwapDex(dex).acceptZenonDex(), "Invalid ZenonSwapDex");
        dex_ = dex;
        opsAuthority_ = msg.sender;
        treasuryAuthority_ = msg.sender;
        emergencyAuthority_ = msg.sender;  
    }



    /* @notice Transfers the existing governance authorities to new addresses. Can only
     *         be invoked by the treasury authority.
     * @dev    One or more of the authority addresses can be kept the same if the caller
     *         only wants to transfer one or two of the authorities. */
    function transferGovernance (address ops, address treasury, address emergency)
        treasuryAuth public {
        opsAuthority_ = ops;
        treasuryAuthority_ = treasury;
        emergencyAuthority_ = emergency;  
        Timelock(payable(treasury)).acceptAdmin();
        Timelock(payable(ops)).acceptAdmin();
        Timelock(payable(emergency)).acceptAdmin();
    }

    /* @notice Resolution from the ops authority which calls protocolCmd() on the 
     *         underlying ZenonSwapDex contract. 
     *
     * @param minion The address of the underlying ZenonSwapDex contract the command is
     *               called on.
     * @param proxyPath The proxy sidecar index the policy calls
     * @param cmd    The content of the command passed to the protocolCmd() method. */
    function opsResolution (address minion, uint16 proxyPath,
                            bytes calldata cmd) opsAuth public {
        emit ZenonResolutionOps(minion, cmd);
        IZenonMinion(minion).protocolCmd(proxyPath, cmd, false);
    }

    /* @notice Resolution from the treasury authority which calls protocolCmd() on the 
     *         underlying ZenonSwapDex contract. 
     *
     * @param minion The address of the underlying ZenonSwapDex contract the command is
     *               called on.
     * @param proxyPath The proxy sidecar index the policy calls
     * @param sudo   If true, runs the call on ZenonSwapDex with elevated privilege
     * @param cmd    The content of the command passed to the protocolCmd() method. */
    function treasuryResolution (address minion, uint16 proxyPath,
                                 bytes calldata cmd, bool sudo)
        treasuryAuth public {
        emit ZenonResolutionTreasury(minion, sudo, cmd);
        IZenonMinion(minion).protocolCmd(proxyPath, cmd, sudo);
    }

    /* @notice An out-of-band emergency measure to protect funds in the ZenonSwapDex 
     *         contract in case of a security issue. It works by disabling all the proxy
     *         contracts in ZenonSwapDex (and disabling swap()'s in the hotpath), besides
     *         the "warm path" proxy. The warm path only includes functionality for flat
     *         mint, burn and harvest calls. An emergency halt would therefore allow LPs
     *         to withdraw their at-rest capital, while reducing the attack radius by 
     *         disabling swaps and more complex long-form orders.
     *
     * @param minion The address of the underlying ZenonSwapDex contract.
     * @param reason The stated reason for invoking the emergency policy update with 
     *               details. */
    function emergencyHalt (address minion, string calldata reason)
        emergencyAuth public {
        emit ZenonEmergencyHalt(minion, reason);

        bytes memory cmd = ProtocolCmd.encodeHotPath(false);
        IZenonMinion(minion).protocolCmd(ZenonSlots.COLD_PROXY_IDX, cmd, true);
        
        cmd = ProtocolCmd.encodeSafeMode(true);
        IZenonMinion(minion).protocolCmd(ZenonSlots.COLD_PROXY_IDX, cmd, true);
    }

    /* @notice Zenon policy rules are set on a per address basis. Each address 
     *         corresponds to a smart contract, which is authorized to invoke one or 
     *         more protocol commands on the underlying ZenonSwapDex contract. 
     * 
     * @param cmdFlags_ A vector of boolean flags. true entry at index X indicates
     *                  that the policy conduit is authorized to invoke protocol
     *                  command code X (192 possible codes).
     * @param mandateTime_ A pre-committed time that the policy will remain in place. Zero
     *                     indicates no mandate and can be changed by ops governance at
     *                     any time. Policy can be strengthened in a mandate, but only
     *                     weakened by treasury governance. 
     * @param expiryOffset_ A maximum TTL for the policy to be in place relative to 
     *                      mandateTime. (If mandateTime is zero then this is just block
     *                      time.) Beyond this time the policy will be considered expired
     *                      and the conduit will have no protocolCmd powers until 
     *                      refreshed by governance. */
    struct PolicyRule {
        bytes32 cmdFlags_;
        uint32 mandateTime_;
        uint32 expiryOffset_;
    }

    /* @notice The set of extant policy rules mapped by originating policy conduit oracle
     *         address. */
    mapping(bytes32 => PolicyRule) public rules_;

    /* @notice Called by policy oracle to invoke protocolCmd on the underlying 
     *         ZenonSwapDex. Authority for the specific protocol command is checked 
     *         against the policy rule (if any) for the conduit oracle's address in the 
     *         policy rules set.
     *
     * @param minion The address of the underlying ZenonSwapDex contract
     * @param proxyPath The proxy sidecar index for the policy being invoked
     * @param cmd    The content of the command passed to protocolCmd() */
    function invokePolicy (address minion, uint16 proxyPath, bytes calldata cmd) public {
        bytes32 ruleKey = keccak256(abi.encode(msg.sender, proxyPath));
        PolicyRule memory policy = rules_[ruleKey];
        require(passesPolicy(policy, cmd), "Policy authority");
        IZenonMinion(minion).protocolCmd(proxyPath, cmd, false);
    }

    /* @notice Called by ops authority to set or update a new policy rules. The only
     *         restriction is that authority to set a protocol command type cannot be
     *         revoked before the mandate time.
     *
     * @param conduit The address of the conduit oracle this policy rule applies to.
     * @param proxyPath The proxy sidecar index the policy calls
     * @param policy  The content of the updated policy rule. This will fully overwrite
     *                the previous policy rule (if any), assuming the transition is legal
     *                relative to the mandate. */    
    function setPolicy (address conduit, uint16 proxyPath,
                        PolicyRule calldata policy) opsAuth public {
        bytes32 key = rulesKey(conduit, proxyPath);
        
        PolicyRule storage prev = rules_[key];
        require(isLegal(prev, policy), "Illegal policy update");

        rules_[key] = policy;
        emit ZenonPolicySet(conduit, proxyPath, policy);
    }

    function rulesKey (address conduit, uint16 proxyPath)
        private pure returns (bytes32) {
        return keccak256(abi.encode(conduit, proxyPath));
    }

    /* @notice Called by treasury authority to set or update a new policy rules. Only
     *         difference with setPolicy is this can revoke policies even inside the 
     *         mandate time. As such this should only be called in unusual circumstances.
     *
     * @param conduit The address of the conduit oracle this policy rule applies to.
     * @param proxyPath The proxy sidecar index the policy calls
     * @param policy  The content of the updated policy rule. This will fully overwrite
     *                the previous policy rule. */
    function forcePolicy (address conduit, uint16 proxyPath, PolicyRule calldata policy)
        treasuryAuth public {
        bytes32 key = rulesKey(conduit, proxyPath);
        rules_[key] = policy;
        emit ZenonPolicyForce(conduit, proxyPath, policy);
    }

    /* @notice Called by emergency authority to set or update a new policy rules. Only
     *         difference with setPolicy is this can revoke policies even inside the 
     *         mandate time. As such this should only be called in unusual circumstances.
     *
     * @param conduit The address of the conduit oracle this policy rule applies to.
     * @param proxyPath The proxy sidecar index the policy calls
     * @param policy  The content of the updated policy rule. This will fully overwrite
     *                the previous policy rule. */
    function emergencyReset (address conduit, uint16 proxyPath,
                             string calldata reason) emergencyAuth public {
        bytes32 key = rulesKey(conduit, proxyPath);
        rules_[key].cmdFlags_ = bytes32(0);
        rules_[key].mandateTime_ = 0;
        rules_[key].expiryOffset_ = 0;
        emit ZenonPolicyEmergency(conduit, reason);
    }

    /* @notice Determines if the Policy transition for this conduit is legal given the
     *         pre-existing policy state.
     * @return Returns true if the policy iteration either 1) occurs outside the mandate
     *         or 2) the new policy does not revoke any pre-existing command flags. */
    function isLegal (PolicyRule memory prev, PolicyRule memory next)
        private view returns (bool) {
        if (weakensPolicy(prev, next)) {
            return isPostMandate(prev);
            
        }
        return true;
    }

    /* @notice Determines if we're operating inside an existing mandate window. */
    function isPostMandate (PolicyRule memory prev) private view returns (bool) {
        return SafeCast.timeUint32() > prev.mandateTime_;
    }

    /* @notice Returns true if the proposed policy weakens any of the guarantees
     *         of the existing policy. This would occur either by revoking an existing
     *         flag or shortening the mandate window. */
    function weakensPolicy (PolicyRule memory prev, PolicyRule memory next)
        private pure returns (bool) {
        bool weakensCmd = prev.cmdFlags_ & ~next.cmdFlags_ > 0;
        bool weakensMandate = next.mandateTime_ < prev.mandateTime_;
        return weakensCmd || weakensMandate;
    }

    /* @notice Determines if the proposed protocolCmd conforms to an existing policy.
     * @param policy The current policy in place for the conduit invoking the command
     * @param protocolCmd The proposed command to be invoked on the underlying 
     *                    ZenonSwapDex contract.
     * @return Returns true if the proposed protocolCmd message is authorized by the 
     *         policy object. */
    function passesPolicy (PolicyRule memory policy, bytes calldata protocolCmd)
        public view returns (bool) {
        if (SafeCast.timeUint32() >= expireTime(policy)) {
            return false;
        }
        uint8 flagIdx = uint8(protocolCmd[31]);
        return isFlagSet(policy.cmdFlags_, flagIdx);
    }

    function expireTime (PolicyRule memory policy) private pure returns (uint32) {
        return policy.mandateTime_ + policy.expiryOffset_;
    }

    /* @notice Returns true if the flag at index is set on the policy command flag 
     *         vector  */
    function isFlagSet (bytes32 cmdFlags, uint8 flagIdx) private pure returns (bool) {
        return (bytes32(uint256(1)) << flagIdx) & cmdFlags > 0;         
    }

    function acceptsZenonAuthority() public override pure returns (bool) { return true; }

    /* @notice Permissions gate for normal day-to-day operations. */
    modifier opsAuth() {
        require(msg.sender == opsAuthority_ ||
                msg.sender == treasuryAuthority_ ||
                msg.sender == emergencyAuthority_, "Ops Authority");
        _;
    }

    /* @notice Permissions gate for more serious operations. Treasury authority should
     *         require more governance controls (e.g. larger multisig, longer timelock)
     *         than operations. */
    modifier treasuryAuth() {
        require(msg.sender == treasuryAuthority_, "Treasury Authority");
        _;
    }

    /* @notice Permissions gate for emergency operations that should only be called
     *         during periods when the security of the protocol is in threat. */
    modifier emergencyAuth() {
        require(msg.sender == emergencyAuthority_, "Emergency Authority");
        _;
    }


}
