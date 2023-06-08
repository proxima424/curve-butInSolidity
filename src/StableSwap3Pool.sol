// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

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

    function _A() internal view returns(uint256) {
        // Handle ramping A up or down

        uint256 t1 = future_A_time;
        uint256 A1 = future_A;

        if(block.timestamp< t1){
            uint256 A0 = initial_A;
            uint256 t0 = initial_A_time;

            if(A1>A0){
                return A0 + (A1 - A0) * (block.timestamp - t0) / (t1 - t0);
            }
            else{
                return A0 - (A0 - A1) * (block.timestamp - t0) / (t1 - t0);
            }
        }
        else{
            return A1;
        }
    }

    function A() external view returns(uint256){
        return _A();
    }

    function _xp() internal view returns(uint256[3] memory){
        uint256[3] memory result = RATES;
        for(uint8 i;i<3;){
            result[i] *= balances[i];
            unchecked{
                ++i;
            }
        }
    }

    function _xp_mem(uint256[3] memory _balances) internal view returns(uint256[3] memory){
        uint256[3] memory result = RATES;
        for(uint8 i;i<3;){
            result[i] *= _balances[i] / PRECISION ;
            unchecked {
                ++i;
            }
        }
    }

    function get_D(uint256[3] memory xp, uint256 amp) internal view returns(uint256){
        uint256 S;
        for(uint8 i;i<3;){
            S += xp[i];
            unchecked {
                ++i;
            }
        }
        if (S==0){
            return 0;
        }

        uint256 Dprev;
        uint256 D = S;
        uint256 Ann = amp * 3;

        for(uint8 i; i<255;){
            uint256 D_P = D;
            for(uint8 j; j<3;){
                // If division by 0, this will be borked: only withdrawal will work. And that is good
                D_P = (D_P * D) / (_xp[j] * 3);
            }
            Dprev = D;
            D = (Ann * S + D_P * 3 ) * D ;
            D = D / ( (Ann - 1 )*D + 4*D_P );
            if D > Dprev{
                if( D - Dprev <= 1){
                    break;
                }
            }
            else{
                if ( Dprev - D <=1 ){
                    break;
                }
            }
            unchecked {
                ++i;
            }
        }
        return D;
    }

    function get_D_mem(uint256[3] memory _balances, uint256 amp) internal view returns(uint256){
        return get_D(_balances,amp);
    }

    function get_virtual_price() external view returns(uint256){
        // Returns portfolio virtual price (for calculating profit) scaled up by 1e18
        uint256 D = get_D(_xp(),_A());
        uint256 total_supply = token.totalSupply();
        return D* PRECISION / total_supply ;
    }

    function calc_token_amount(uint256[3] memory amounts, bool deposit) returns(uint256){
        // Simplified method to calculate addition or reduction in token supply at
        // deposit or withdrawal without taking fees into account (but looking at slippage)
        // Needed to prevent front-running, not for precise calculations!

        uint256[3] memory _balances = balances;
        uint256 amp = _A();
        uint256 D0 = get_D_mem(_balances,amp);

        for(uint8 i;i<3;){
            if(deposit){
                _balances[i] += amounts[i];
            }
            else{
                _balances[i] -= amounts[i];
            }
            unchecked {
                ++i;
            }
        }

        uint256 D1 = get_D_mem(_balances,amp);

        uint256 token_amount = token.totalSupply();

        uint256 diff;

        if(deposit){
            diff = D1 - D0;
        }
        else{
            diff = D0 - D1;
        }

        return diff * token_amount / D0 ;
    }

    // what does nonReentrant('lock') mean in vyper?
    function add_liquidity(uint256[3] memory amounts, uint256 min_mint_amount) external nonReentrant{
        require(!is_killed);

        uint256[3] memory fees;
        uint256 _fee = (fee * 3) / 8;
        uint256 _admin_fee = admin_fee;
        uint256 amp = _A();

        uint256 token_supply = token.totalSupply();

        // Initial Invariant
        uint256 D0;
        uint256[3] memory old_balances = balances;

        if(token_supply>0){
            D0 = get_D_mem(old_balances,amp);
        }
        uint256[3] memory new_balances = old_balances;

        for(uint8 i;i<3;){
            uint256 in_amount = amounts[i];

            if(token_supply==0){
                require(in_amount>0);
            }

            address in_coin = coins[i];

            if(in_amount>0){
                if(i==FEE_INDEX){
                    in_amount = IERC20(in_coin).balanceOf(address(this));
                }
            }
            unchecked {
                ++i;
            }
        }
    }














}
