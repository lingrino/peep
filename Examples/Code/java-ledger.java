package com.example.bank;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/** A tiny ledger with accounts and transfers. */
public class Ledger {
    public record Transfer(String from, String to, BigDecimal amount) {}

    public static class InsufficientFunds extends Exception {
        public InsufficientFunds(String account, BigDecimal balance) {
            super("Account " + account + " has only " + balance);
        }
    }

    private final List<Account> accounts = new ArrayList<>();
    private final List<Transfer> history = new ArrayList<>();

    public Account open(String id, BigDecimal initial) {
        Account account = new Account(id, initial);
        accounts.add(account);
        return account;
    }

    public Optional<Account> find(String id) {
        return accounts.stream().filter(a -> a.id().equals(id)).findFirst();
    }

    public void transfer(String from, String to, BigDecimal amount) throws InsufficientFunds {
        Account source = find(from).orElseThrow();
        Account target = find(to).orElseThrow();
        if (source.balance().compareTo(amount) < 0) {
            throw new InsufficientFunds(from, source.balance());
        }
        source.withdraw(amount);
        target.deposit(amount);
        history.add(new Transfer(from, to, amount));
    }

    public BigDecimal total() {
        return accounts.stream().map(Account::balance).reduce(BigDecimal.ZERO, BigDecimal::add);
    }

    public List<Transfer> history() {
        return List.copyOf(history);
    }

    public static final class Account {
        private final String id;
        private BigDecimal balance;

        Account(String id, BigDecimal balance) {
            this.id = id;
            this.balance = balance;
        }

        public String id() { return id; }

        public BigDecimal balance() { return balance; }

        void deposit(BigDecimal amount) { balance = balance.add(amount); }

        void withdraw(BigDecimal amount) { balance = balance.subtract(amount); }
    }

    public static void main(String[] args) throws Exception {
        Ledger ledger = new Ledger();
        ledger.open("alice", new BigDecimal("100.00"));
        ledger.open("bob", BigDecimal.TEN);
        ledger.transfer("alice", "bob", new BigDecimal("25.50"));
        System.out.printf("total=%s transfers=%d%n", ledger.total(), ledger.history().size());
    }
}
