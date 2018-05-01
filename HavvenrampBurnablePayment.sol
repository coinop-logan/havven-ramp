// A HavvenrampBurnablePayment is a modification of the BurnablePayment contract, with two main differences:
//
// First, it adds in support for ERC20 tokens.
//
// Second, it replaces the worker-called "Commit" function with the payer-called "ApproveWorker" function.
// This allows a user without ETH to be registered/approved as the recipient,
// and assumes such a user has a way of contacting the payer to request said registration.
//
// This modification has been sponsored by Havven,
// to be used in the development of a robust, decentralized crypto on-ramp.

pragma solidity ^ 0.4.23;

contract ERC20Interface {
    function totalSupply() public constant returns (uint);
    function balanceOf(address tokenOwner) public constant returns (uint balance);
    function allowance(address tokenOwner, address spender) public constant returns (uint remaining);
    function transfer(address to, uint tokens) public returns (bool success);
    function approve(address spender, uint tokens) public returns (bool success);
    function transferFrom(address from, address to, uint tokens) public returns (bool success);

    event Transfer(address indexed from, address indexed to, uint tokens);
    event Approval(address indexed tokenOwner, address indexed spender, uint tokens);
}

contract HavvenrampBurnablePaymentFactory {
    event NewHBP(
        address indexed bpAddress,
        address tokenManager,
        uint deposited,
        address payer,
        uint autoreleaseInterval,
        string title,
        string initialStatement
    );

    function newEtherHBP(address payer, uint autoreleaseInterval, string title, string initialStatement)
    external
    payable
    returns (address)
    {
        emit NewHBP(newHBPAddress, address(0x0), msg.value, payer, autoreleaseInterval, title, initialStatement);

        //pass along any ether to the constructor
        address newHBPAddress = (new HavvenrampBurnablePayment).value(msg.value)(address(0x0), payer, autoreleaseInterval, title, initialStatement);

        return newHBPAddress;
    }

    //Previous to this call, the token's "approve" method should have been called for the Factory address.
    function newTokenHBP(address tokenManagerAddress, uint tokenAmount, address payer, uint autoreleaseInterval, string title, string initialStatement)
    external
    returns (address)
    {
        emit NewHBP(newHBPAddress, tokenManagerAddress, tokenAmount, payer, autoreleaseInterval, title, initialStatement);

        address newHBPAddress = new HavvenrampBurnablePayment(tokenManagerAddress, payer, autoreleaseInterval, title, initialStatement);

        //Now transfer tokens to the HBP address
        ERC20Interface tokenManagerContract = ERC20Interface(tokenManagerAddress);
        tokenManagerContract.transferFrom(msg.sender, newHBPAddress, tokenAmount);

        // We assumed above that the tokens are coming from msg.sender, since msg.sender is signing this transaction anyway.
        // We could have instead assumed that payer is supplying the tokens, but this would require two separate signatures from the client:
        // one from msg.sender (to generate this tx) and another from payer, to call the approve method.

        return newHBPAddress;
    }
}

contract HavvenrampBurnablePayment {
    //If it's a token HBP, it will have a token manager address (if not, this will be set to 0x0)
    ERC20Interface tokenManager;

    function isTokenHBP()
    public
    constant
    returns (bool) {
        return (address(tokenManager) != address(0x0));
    }

    //title will never change
    string public title;

    //HBP will start with a payer but not a recipient
    address public payer;
    address public recipient;

    address constant BURN_ADDRESS = 0x0;

    //these two variables track the relevant totals, but don't affect HBP logic
    uint amountBurned;
    uint amountReleased;

    //Set to true if fundsRecovered is called (offers another method of detecting recalled HBPs)
    bool recovered = false;

    //How long should we wait before allowing the default release to be called?
    uint public autoreleaseInterval;

    //Calculated from autoreleaseInterval in commit(),
    //and recaluclated whenever the payer calls delayDefaultRelease()
    //After this time, auto-release can be called by any address.
    uint public autoreleaseTime;

    //Most action happens in the Committed state.
    enum State {
        Open,
        Committed,
        Closed
    }

    //Note that a HBP cannot go from Committed back to either Open state, but it can go from Closed back to Committed
    //Search for Closed and Unclosed events to see how this works.
    State public state;

    modifier inState(State s) {
        require(s == state);
        _;
    }
    modifier onlyPayer() {
        require(msg.sender == payer);
        _;
    }

    event PayerStatement(string statement);
    event FundsRecovered();

    constructor(address tokenManagerAddress, address _payer, uint _autoreleaseInterval, string _title, string initialStatement)
    public
    payable
    {
        if (tokenManagerAddress != address(0x0)) {
            tokenManager = ERC20Interface(tokenManagerAddress);
        }
        payer = _payer;
        title = _title;
        state = State.Open;
        autoreleaseInterval = _autoreleaseInterval;

        require( !(isTokenHBP() && msg.value > 0), "Cannot create HBP with both ether and an ERC20 token manager address.");

        emit PayerStatement(initialStatement);
    }

    function getBalance()
    public
    constant
    returns (uint)
    {
        if (isTokenHBP()) {
            return tokenManager.balanceOf(address(this));
        }
        else {
            return address(this).balance;
        }
    }

    function addEther()
    external
    payable
    onlyPayer()
    {
        require(!isTokenHBP());
        require(msg.value > 0);

        if (state == State.Closed) {
            state = State.Committed;
        }
    }

    function addTokens(uint amount)
    external
    onlyPayer()
    {
        require(isTokenHBP());

        tokenManager.transferFrom(msg.sender, address(this), amount);

        if (state == State.Closed) {
            state == State.Committed;
        }
    }

    function recoverFunds()
    external
    onlyPayer()
    inState(State.Open)
    {
        recovered = true;
        emit FundsRecovered();

        if (isTokenHBP()) {
            tokenManager.transfer(payer, tokenManager.balanceOf(address(this)));
        }
        selfdestruct(payer);
    }

    function approveRecipient(address _recipient)
    external
    payable
    onlyPayer()
    inState(State.Open)
    {
        recipient = _recipient;

        state = State.Committed;

        autoreleaseTime = now + autoreleaseInterval;
    }

    function internalBurn(uint amount)
    internal
    {
        if (isTokenHBP()) {
            tokenManager.transfer(BURN_ADDRESS, amount);
        }
        else {
            BURN_ADDRESS.transfer(amount);
        }

        amountBurned += amount;

        if (getBalance() == 0) {
            state = State.Closed;
        }
    }

    function burn(uint amount)
    external
    inState(State.Committed)
    onlyPayer()
    {
        internalBurn(amount);
    }

    function internalRelease(uint amount)
    internal
    {
        if (isTokenHBP()) {
            tokenManager.transfer(recipient, amount);
        }
        else {
            recipient.transfer(amount);
        }

        amountReleased += amount;

        if (address(this).balance == 0) {
            state = State.Closed;
        }
    }

    function release(uint amount)
    external
    inState(State.Committed)
    onlyPayer()
    {
        internalRelease(amount);
    }

    function logPayerStatement(string statement)
    external
    onlyPayer()
    {
        emit PayerStatement(statement);
    }

    function delayAutorelease()
    external
    onlyPayer()
    inState(State.Committed)
    {
        autoreleaseTime = now + autoreleaseInterval;
    }

    function triggerAutorelease()
    external
    inState(State.Committed)
    {
        require(now >= autoreleaseTime);

        internalRelease(getBalance());
    }

    function getFullState()
    external
    constant
    returns(address, State, address, address, string, uint, uint, uint, uint, uint) {
        return (address(tokenManager), state, payer, recipient, title, getBalance(), amountBurned, amountReleased, autoreleaseInterval, autoreleaseTime);
    }
}
