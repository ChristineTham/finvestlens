//
//  CAMTImport.swift
//  FinvestLens — Interchange
//
//  Copyright (C) 2026 Christine Tham
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Parses ISO 20022 **CAMT.053** bank-to-customer statements (`FR-XIO-04`) —
/// and, because the entry structure is identical, CAMT.052 account reports.
///
/// A streaming `XMLParser` reads each `<Ntry>` into one staged row:
/// - `Amt` signed by `CdtDbtInd` (`DBIT` → negative), flipped again by a true
///   `RvslInd` (a booked reversal undoes the original direction);
/// - entries whose status is `PDNG` are skipped — they re-arrive booked on the
///   next statement (both the plain `<Sts>` text and the nested `<Sts><Cd>`
///   of the .001.08+ versions are read);
/// - the date is the booking date, value date as fallback;
/// - the reference (for FITID-style dedupe) prefers the entry's
///   `AcctSvcrRef`, then the transaction detail's `AcctSvcrRef`/`TxId`, then a
///   meaningful `EndToEndId` (banks fill "NOTPROVIDED" when absent);
/// - the payee is the counterparty: the creditor's name on a debit, the
///   debtor's on a credit (both the direct `<Nm>` and the nested `<Pty><Nm>`
///   of newer versions);
/// - the memo joins the unstructured remittance lines (`RmtInf/Ustrd`),
///   falling back to `AddtlNtryInf`.
///
/// A batched entry (several `TxDtls` under one `Ntry`) stays one row at the
/// entry amount — the counterparty/reference of its first detail — matching
/// how the statement books it as a single movement.
public enum CAMTImporter {

    public static func parse(_ data: Data) -> [StagedTransaction] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    public static func parse(_ text: String) -> [StagedTransaction] {
        parse(Data(text.utf8))
    }
}

private final class Delegate: NSObject, XMLParserDelegate {
    var rows: [StagedTransaction] = []

    private var path: [String] = []
    private var text = ""

    // Current <Ntry> being assembled.
    private var inEntry = false
    private var amount: Decimal?
    private var isDebit = false
    private var isReversal = false
    private var status = ""
    private var bookingDate: Date?
    private var valueDate: Date?
    private var entryReference = ""
    private var detailReference = ""
    private var transactionID = ""
    private var endToEndID = ""
    private var creditorName = ""
    private var debtorName = ""
    private var remittance: [String] = []
    private var additionalInfo = ""
    /// Only the first `TxDtls` of a batched entry contributes details.
    private var detailIndex = 0

    /// Element name without any namespace prefix (files usually use a default
    /// namespace, but a `camt:`-prefixed document should parse the same).
    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    func parser(_ parser: XMLParser, didStartElement name: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        let name = Self.local(name)
        path.append(name)
        text = ""
        if name == "Ntry" {
            inEntry = true
            amount = nil; isDebit = false; isReversal = false; status = ""
            bookingDate = nil; valueDate = nil
            entryReference = ""; detailReference = ""; transactionID = ""; endToEndID = ""
            creditorName = ""; debtorName = ""; remittance = []; additionalInfo = ""
            detailIndex = 0
        }
        if inEntry, name == "TxDtls" { detailIndex += 1 }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement name: String,
                namespaceURI: String?, qualifiedName: String?) {
        let name = Self.local(name)
        defer { path.removeLast(); text = "" }
        guard inEntry else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "Ntry":
            finishEntry()
            inEntry = false
        case "Amt" where parent(1) == "Ntry":
            amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX"))
        case "CdtDbtInd" where parent(1) == "Ntry":
            isDebit = (value == "DBIT")
        case "RvslInd" where parent(1) == "Ntry":
            isReversal = (value.lowercased() == "true")
        case "Sts" where parent(1) == "Ntry":
            if !value.isEmpty { status = value }
        case "Cd" where parent(1) == "Sts":
            status = value
        case "Dt", "DtTm":
            let date = Self.date(value)
            if parent(1) == "BookgDt" { bookingDate = date }
            if parent(1) == "ValDt" { valueDate = date }
        case "AcctSvcrRef":
            if parent(1) == "Ntry" {
                entryReference = value
            } else if detailIndex == 1, detailReference.isEmpty {
                detailReference = value
            }
        case "TxId" where detailIndex == 1 && parent(1) == "Refs":
            transactionID = value
        case "EndToEndId" where detailIndex == 1:
            endToEndID = value
        case "Nm":
            guard detailIndex <= 1 else { break }
            // Cdtr/Nm or Cdtr/Pty/Nm (and the debtor equivalents).
            let holder = parent(1) == "Pty" ? parent(2) : parent(1)
            if holder == "Cdtr", creditorName.isEmpty { creditorName = value }
            if holder == "Dbtr", debtorName.isEmpty { debtorName = value }
        case "Ustrd" where detailIndex <= 1:
            if !value.isEmpty { remittance.append(value) }
        case "AddtlNtryInf":
            additionalInfo = value
        default:
            break
        }
    }

    /// The element `levels` above the one currently ending.
    private func parent(_ levels: Int) -> String {
        let index = path.count - 1 - levels
        return index >= 0 ? path[index] : ""
    }

    private func finishEntry() {
        guard status != "PDNG", let amount, amount != 0,
              let date = bookingDate ?? valueDate else { return }
        var negative = isDebit
        if isReversal { negative.toggle() }

        let reference = !entryReference.isEmpty ? entryReference
            : !detailReference.isEmpty ? detailReference
            : !transactionID.isEmpty ? transactionID
            : (endToEndID.uppercased() != "NOTPROVIDED" ? endToEndID : "")
        let payee = isDebit ? creditorName : debtorName
        let memo = remittance.isEmpty ? additionalInfo : remittance.joined(separator: " ")

        rows.append(StagedTransaction(date: date,
                                      amount: negative ? -amount : amount,
                                      payee: payee, memo: memo,
                                      reference: reference))
    }

    private static func date(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(raw.prefix(10)))
    }
}
