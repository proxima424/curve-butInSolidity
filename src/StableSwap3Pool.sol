// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

interface CurveToken {
    function totalSupply() external view returns (uint256);
    // Functions in Solidity interfaces can not have modifiers
    // Unlike in vyper, where these two following functions
    // have "nonpayable" modifiers in their vyper interfaces
    function mint(address _to, uint256 _value) external returns (bool);
    function burn(address _to, uint256 _value) external returns (bool);
}

contract StableSwap3Pool {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event TokenExchange(
        address indexed buyer, int128 sold_id, uint256 tokens_sold, int128 bought_id, uint256 tokens_bought
    );

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ERRORS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    error ZeroAddress();

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         STORAGE                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    int128 public immutable N_COINS = 3;
    uint256 public immutable FEE_DENOMINATOR = 10**10;
    uint256 public immutable LENDING_PRECISION = 10**18;
    uint256 public immutable PRECISION = 10**18;

    // NOTE
    uint256[3] public PRECISION_MUL = [1, 1000000000000, 1000000000000];
    uint256[3] public RATES = [1000000000000000000, 1000000000000000000000000000000, 1000000000000000000000000000000];

    int128 public immutable FEE_INDEX = 2;
    uint256 public immutable MAX_ADMIN_FEE = 10**10;
    uint256 public immutable MAX_FEE = 5*(10**9);
    uint256 public immutable MAX_A = 10**6;
    uint256 public immutable MAX_A_CHANGE = 10;

    uint256 public immutable ADMIN_ACTIONS_DELAY = 3*86400;
    uint256 public immutable MIN_RAMP_TIME = 86400;

    address[3] public coins;
    uint256[3] public balances;
    uint256 public fee;
    uint256 public admin_fee;

    address public owner;
    CurveToken public token;

    uint256 public initial_A;
    uint256 public future_A;
    uint256 public initial_A_time;
    uint256 public future_A_time;

    uint256 public admin_actions_deadline;
    uint256 public transfer_ownership_deadline;
    uint256 public future_fee;
    uint256 public future_admin_fee;
    address public future_owner;

    bool public is_killed;
    uint256 public kill_deadline;
    uint256 public immutable KILL_DEADLINE_DT = 2*30*86400;

    constructor(address _owner, address[3] memory _coins, address _pool_token, uint256 _A, uint256 _fee, uint256 _admin_fee){
        for(uint i; i<3; ++i){
            if(_coins[i]==address(0)){
                revert ZeroAddress();
            }
        }
        coins = _coins;
        initial_A = _A;
        future_A = _A;
        fee = _fee;
        admin_fee = _admin_fee;
        owner = _owner;
        kill_deadline = block.timestamp + KILL_DEADLINE_DT;
        token = CurveToken(_pool_token);
    }

    










}
