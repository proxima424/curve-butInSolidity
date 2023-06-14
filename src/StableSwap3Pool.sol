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

    event AddLiquidity(address indexed provider,uint256[3] token_amounts, uint256[3] fees, uint256 invariant, uint256 token_supply);

    event RemoveLiquidityImbalance(address indexed provider, uint256[3] token_amounts, uint256[3] fees, uint256 invariant, uint256 token_supply);

    event RemoveLiquidityOne(address indexed provider, uint256 token_amount, uint256 coin_amount);

    event RemoveLiquidity(address indexed provider, uint256[3] token_amounts, uint256[3] fees, uint256 token_supply);

    event CommitNewAdmin(uint256 indexed deadline, address indexed admin);

    event NewAdmin(address indexed admin);

    event CommitNewFee(uint256 indexed deadline, uint256 fee, uint256 admin_fee);

    event NewFee(uint256 fee, uint256 admin_fee);

    event RampA(uint256 old_A, uint256 new_A, uint256 initial_time, uint256 future_time);

    event StopRampA(uint256 A, uint256 t);

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

            // Take coins from Sender
            if(in_amount>0){

                if(i==FEE_INDEX){
                    in_amount = IERC20(in_coin).balanceOf(address(this));
                }

                bool success = IERC20(in_coin).transferFrom(msg.sender,address(this),in_amount);
                require(success,"Transfer Failed");

                if(i==FEE_INDEX){
                    in_amount = IERC20(in_coin).balanceOf(address(this)) - in_amount;
                }
            }
            new_balances[i] += in_amount;
            unchecked {
                ++i;
            }
        }

        // INVARIANT AFTER CHANGE
        uint256 D1 = get_D_mem(new_balances,amp);
        require(D1>D0);

        // We need to recalculate the invariant accounting for fees
        // to calculate fair user's share

        uint256 D2 = D1;

        if token_supply>0 {
            // Only account for fees if we are not the first to deposit
            for(uint256 i; i<3;){
                uint256 ideal_balance = ( D1 * old_balances[i]) / D0;
                uint256 difference = 0;

                if(ideal_balance>new_balances[i]){
                    difference = ideal_balance - new_balances[i];
                }
                else{
                    difference = new_balances[i] - ideal_balance;
                }
                fees[i] = (_fee * difference ) / FEE_DENOMINATOR;
                balances[i] = new_balances[i] - ( (fees[i]*_admin_fee) / FEE_DENOMINATOR );
                new_balances[i] -= fees[i];
                unchecked{
                    ++i;
                }
            }

            D2 = get_D_mem(new_balances, amp);
        }
        else{
            balances = new_balances;
        }

        // Calculate how much pool tokens to mint
        uint256 mint_amount = 0;
        if(token_supply==0){
            // Take the dust if any? wtf does this mean
            mint_amount = D1;
        }
        else{
            mint_amount = token_supply* (D2-D0) / D0;
        }

        require(mint_amount >= min_mint_amount, "Slippage screwed you");

        // Mint pool tokens
        IERC20(token).mint(msg.sender,mint_amount);

        emit AddLiquidity(msg.sender,amounts,fees,D1,token_supply + mint_amount);

    }

    function get_y(int128 i, int128 j,uint256 x, uint256[3] memory xp_) internal view returns(uint256){

        // x in the input is converted to the same price/precision
        require(i!=j , " same coin");
        require(j>=0, " j beelow zero");
        require(j< 3, " huh ");

        // should be unreachable, but good for safety
        require(i>=0);
        require(i<3);

        uint256 amp = _A();
        uint256 D = get_D(xp_,amp);
        uint256 c = D;
        uint256 S_ = 0;
        uint256 Ann = amp * 3;

        uint256 _x = 0;
        for(uint256 _i;_i<3;){
            if _i == i {
            _x = x
            }
            else if( _i != j){
                _x = xp_[_i];
            }
            S_ += _x ;
            c = c * D / (_x * 3);
            unchecked{
                ++_i;
            }
        }

        c = c*D / (ANN * 3 );

        uint256 b = (S_ + D) / Ann;

        uint256 y_prev = 0;
        uint256 y = D;

        for(uint k;k<255;){

            y_prev = y;
            y = (y*y+c) / (2*y + b - D);

            // Equality with the precision of 1

            if y > y_prev {
                if( y - y_prev <=1){
                    break;
                }
            }
            else{
                if( y_prev - y <=1 ){
                    break;
                }
            }
            unchecked{
                ++k;
            }
        }
        return y;
    }


    function get_dy(int128 i, int128 j, uint256 dx) returns(uint256){
        // dx and dy in c-units
        uint256[3] rates = RATES;
        uint256[3] xp = _xp();

        uint256 x = xp[i] + (dx * rates[i] / PRECISION) ;
        uint256 y = get_y(i, j, x, xp);
        uint256 dy = (xp[j] - y - 1) * PRECISION / rates[j];
        uint256 _fee = fee * dy / FEE_DENOMINATOR;

        return dy - _fee ;
    }

    function get_dy_underlying(int128 i, int128 j, uint256 dx) returns(uint256){
        uint256[3] xp = _xp();
        uint256[3] precisions = PRECISION_MUL;

        uint256 x = xp[i] + dx * precisions[i];
        uint256 y = get_y(i, j, x, xp);
        uint256 dy = (xp[j] - y - 1) / precisions[j];
        uint256 _fee = fee * dy / FEE_DENOMINATOR;

        return dy - _fee;
    }

    function exchange(int128 i,int128 j, uint256 dx, uint256 min_dy)external nonReentrant{
        require(!is_killed);

        uint256[3] rates = RATES;

        uint256[3] old_balances = balances;
        uint256[3] xp = _xp_mem(old_balances);

        // Handling an unexpected charge of a fee on transfer (USDT, PAXG)
        uint256 dx_w_fee = dx;
        address input_coin = coins[i];

        if(i==FEE_INDEX){
            dx_w_fee = IERC20(input_coin).balanceOf(address(this));
        }

        bool success_x = IERC20(input_coin).transferFrom(msg.sender,address(this),dx);
        require(success_x,"Transfer Failed");

        if(i==FEE_INDEX){
            dx_w_fee = IERC20(input_coin).balanceOf(address(this)) - dx_w_fee;
        }

        uint256 x = xp[i] + dx_w_fee * rates[i] / PRECISION ;
        uint256 y = get_y(i, j, x, xp);

        uint256 dy =  xp[j] - y - 1 // -1 just in case there were some rounding errors
        uint256 dy_fee = dy * fee / FEE_DENOMINATOR;

        // Convert all to real units
        dy = (dy - dy_fee) * PRECISION / rates[j] ;
        require( dy >= min_dy, "Exchange resulted in fewer coins than expected");

        uint256 dy_admin_fee = dy_fee * admin_fee / FEE_DENOMINATOR;
        dy_admin_fee = dy_admin_fee * PRECISION / rates[j] ;

        // Change balances exactly in same way as we change actual ERC20 coin amounts
        balances[i] = old_balances[i] + dx_w_fee;
        balances[j] =  old_balances[j] - dy - dy_admin_fee;

        bool success_y = IERC20(coins[j]).transfer(msg.sender,dy);
        require(success_y,"Transfer Failed");

        emit TokenExchange(msg.sender,i,dx,j,dy);
    }

    function remove_liquidity(uint256 _amount, uint256[3] min_amounts) external nonReentrant{
        uint256 total_supply = token.totalSupply();
        uint256[3] amounts;
        // Fees are unused but we've got them historically in event
        uint256[3] fees;

        for(uint256 i;i<3;){
            uint256 value =  balances[i] * _amount / total_supply;
            require(value >= min_amounts[i],"Withdrawal resulted in fewer coins than expected");
            balances[i] -= value;
            amounts[i] = value;

            bool success = IERC20(coins[i]).transfer(msg.sender,value);
            require(success);
            unchecked{
                ++i;
            }
        }

        token.burnFrom(msg.sender,_amount);

        emit RemoveLiquidity(msg.sender,amounts,fees,total_supply - _amount);
    }

    function remove_liquidity_imbalance(uint256[3] amounts, uint256 max_burn_amount) external nonReentrant{
        require(!is_killed);
        uint256 token_supply  = token.totalSupply();
        require(token_supply!=0);

        uint256 _fee = fee * 3 / (4 * (2));
        uint256 _admin_fee = admin_fee;
        uint256 amp = _A();

        uint256[3] old_balances = balances;
        uint256[3] new_balances = old_balances;

        uint256 D0 = get_D_mem(old_balances, amp);

        for(uint256 i;i<3;){
            new_balances[i] -= amounts[i];
            unchecked {
                ++i;
            }
        }

        uint256 D1 = get_D_mem(new_balances, amp);

        uint256[3] fees;

        for(uint256 i;i<3;){
            uint256 ideal_balances = D1 * old_balances[i] / D0;
            uint256 difference;

            if (ideal_balance > new_balances[i]){
                difference = ideal_balance - new_balances[i];
            }
            else{
                difference = new_balances[i] - ideal_balance;
            }

            fees[i] = _fee * difference / FEE_DENOMINATOR;
            balances[i] = new_balances[i] - (fees[i] * _admin_fee / FEE_DENOMINATOR);

            new_balances[i] -= fees[i];


            unchecked {
                ++i;
            }
        }

        uint256 D2 = get_D_mem(new_balances, amp);

        uint256 token_amount =  (D0 - D2) * token_supply / D0;
        require(token_amount!=0);

        token_amount++; //  In case of rounding errors - make it unfavorable for the "attacker"

        require(token_amount <= max_burn_amount, "Slippage screwed you");

        token.burnFrom(msg.sender, token_amount);

        for ( uint256 i; i<3;){
            if(amounts[i] !=0 ){

                bool success = IERC20(coins[i]).transfer(msg.sender,amounts[i]);
                require(success);

            }
            unchecked {
                ++i;
            }
        }

        emit RemoveLiquidityImbalance(msg.sender, amounts, fees, D1, token_supply - token_amount);
    }

    function get_y(uint256 A_, int128 i, uint256[3] xp, uint256 D) internal view returns(uint256){

        //  Calculate x[i] if one reduces D from being calculated for xp to D
        //  Done by solving quadratic equation iteratively.
        //  x_1**2 + x1 * (sum' - (A*n**n - 1) * D / (A * n**n)) = D ** (n + 1) / (n ** (2 * n) * prod' * A)
        //  x_1**2 + b*x_1 = c
        //  x_1 = (x_1**2 + c) / (2*x_1 + b)

        // x in the input is converted to the same price/precision

        require(i>=0);
        require(i<3);

        uint256 c = D;
        uint256 S_ = 0;
        uint256 Ann = A_*3;
        uint256 _x = 0 ;

        for(uint256 j;j<3;){
            if(_i != i){
                _x = xp[_i];
            }

            S_ += _x;
            c = c * D / (_x * 3);

            unchecked {
                ++i;
            }
        }

        c = c * D / (Ann * 3);

        uint256 b = S_ + D / Ann;
        uint256 y_prev;
        uint256 y = D;

        for(uint256 j;j<255;){
            y_prev = y;
            y = (y*y + c) / (2 * y + b - D);

            // Equality with the precision of 1

            if( y> y_prev){
                if( y- y_prev ){
                    break;
                }
            }
            else{
                if ( y_prev - y){
                    break;
                }
            }
            unchecked {
                ++i;
            }
        }

        return y;
    }

    function _calc_withdraw_one_coin(uint256 _token_amount, int128 i) internal view returns(uint256,uint256){

        // First we need to calculate
        // * Get current D
        // Solve Eqn against y_i for D - _token_amount

        uint256 amp = _A();
        uint256 _fee = (fee*3) / 8;
        uint256[3] precisions = PRECISION_MUL;

        uint256 total_supply = token.totalSupply();

        uint256[3] xp = _xp();

        uint256 D0 = get_D(xp, amp);
        uint256 D1 = D0 - _token_amount * D0 / total_supply;

        uint256[3] xp_reduced = xp;

        uint256 new_y = get_y_D(amp, i, xp, D1);
        uint256 dy_0 = (xp[i] - new_y) / precisions[i]  // w/o fees

        for(uint256 j;j<3;){
            uint256 dx_expected;
            if(j==i){
                dx_expected = xp[j] * D1 / D0 - new_y;
            }
            else{
                dx_expected = xp[j] - xp[j] * D1 / D0;
            }
            xp_reduced[j] -= _fee * dx_expected / FEE_DENOMINATOR;
            unchecked {
                ++i;
            }
        }

        uint256 dy = xp_reduced[i] - get_y_D(amp, i, xp_reduced, D1);
        dy = (dy - 1) / precisions[i]  // Withdraw less to account for rounding errors

        return dy, dy_0 - dy
    }

    function calc_withdraw_one_coin ( uint256 _token_amount, int128 i) returns(uint256){
        return _calc_withdraw_one_coin(_token_amount, i)[0];
    }

    function remove_liquidity_one_coin(uint256 _token_amount, int128 i, uint256 min_amount){
        // Remove _amount of liquidity all in a form of coin i

        require(!is_killed);

        (uint256 dy, uint256 dy_fee) = _calc_withdraw_one_coin(_token_amount, i);

        require(dy>=min_amount,"Not enough coins removed");

        balances[i] -= (dy + dy_fee * admin_fee / FEE_DENOMINATOR);
        token.burnFrom(msg.sender, _token_amount);

        bool success = IERC20(coins[i]).transfer(msg.sender,dy);

        require(success);

        emit RemoveLiquidityOne(msg.sender, _token_amount, dy);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ADMIN FUNCTIONS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function ramp_A(uint256 _future_A, uint256 _future_time) external {

        require(msg.sender == owner);
        require(block.timestamp >= initial_A_time + MIN_RAMP_TIME);
        require(_future_time >= block.timestamp + MIN_RAMP_TIME, "insufficient time");

        uint256 _initial_A = _A();

        require( (_future_A > 0) && (_future_A < MAX_A) );

        require(((_future_A >= _initial_A) && (_future_A <= _initial_A * MAX_A_CHANGE))  ||   ( (_future_A < _initial_A) && (_future_A * MAX_A_CHANGE >= _initial_A) ));

        initial_A = _initial_A;
        future_A = _future_A;
        initial_A_time = block.timestamp;
        future_A_time = _future_time;

        emit RampA(_initial_A, _future_A, block.timestamp, _future_time);
    }

    function stop_ramp_A() external {
        require(msg.sender == owner);

        uint256 current_A = _A();
        initial_A = current_A;
        future_A = current_A;
        initial_A_time = block.timestamp;
        future_A_time = block.timestamp;

        // now (block.timestamp < t1) is always False, so we return saved A

        emit StopRampA(current_A, block.timestamp);
    }

    function commit_new_fee(uint256 new_fee, uint256 new_admin_fee ) external{

        require(msg.sender == owner);
        require(admin_actions_deadline == 0);
        require(new_fee <= MAX_FEE);
        require(new_admin_fee <= MAX_ADMIN_FEE);

        uint256 _deadline = block.timestamp + ADMIN_ACTIONS_DELAY;
        admin_actions_deadline = _deadline;
        future_fee = new_fee;
        future_admin_fee = new_admin_fee;

        emit CommitNewFee(_deadline, new_fee, new_admin_fee);
    }

    function apply_new_fee() external {
        require(msg.sender == owner);
        require(block.timestamp >= admin_actions_deadline);
        require(admin_actions_deadline != 0);

        admin_actions_deadline = 0;
        uint256 _fee = future_fee;
        uint256 _admin_fee = future_admin_fee;
        fee = _fee;
        admin_fee = _admin_fee;

        emit NewFee(_fee, _admin_fee);

    }

    function revert_new_parameters() external {
        require(msg.sneder == owner);
        admin_actions_deadline = 0;
    }

    function commit_transfer_ownership(address _owner) external {
        require(msg.sender == owner);
        require(transfer_ownership_deadline == 0, "active transfer");

        uint256 _deadline = block.timestamp + ADMIN_ACTIONS_DELAY;
        transfer_ownership_deadline = _deadline;
        future_owner = _owner;

        emit CommitNewAdmin(_deadline, _owner);
    }

    function apply_transfer_ownership() external {
        require(msg.sender == owner);
        require(block.timestamp >= transfer_ownership_deadline, "insufficient time" );
        require(transfer_ownership_deadline != 0 , "no active transfer");

        transfer_ownership_deadline = 0;
        address _owner = future_owner;
        owner = _owner;

        emit NewAdmin(_owner);
    }

    function revert_transfer_ownership() external {
        require(msg.sender == owner);
        transfer_ownership_deadline = 0;
    }

    function admin_balances(uint256 i) external view returns(uint256){
        return IERC20(coins[i]).balanceOf(address(this)) - balances[i];
    }

    function withdraw_admin_fees() external {
        require(msg.sender == owner);

        for(uint256 i;i<3;){

            address c = coins[i];
            uint256 value = IERC20(coins[i]).balanceOf(address(this)) - balances[i];

            if(value>0){
                bool success = IERC20(coins[i]).transfer(msg.sender,value);
                require(success);
            }

            unchecked {
                ++i;
            }
        }
    }

    function donate_admin_fees() external {
        require(msg.sender == owner);

        for( uint256 i;i<3;){
            balances[i] = IERC20(coins[i]).balanceOf(address(this));
            unchecked {
                ++i;
            }
        }
    }

    function kill_me() external {
        require(msg.sender == owner);
        require(kill_deadline > block.timestamp);

        is_killed = true;
    }

    function unkill_me() external {
        require(msg.sender == owner);
        is_killed = false;
    }

}
